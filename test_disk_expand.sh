#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration & Argument Parsing ---
EL_VERSION=${1:-10} # Default to 10 if no argument is provided
ARCH=${2:-arm}      # Default to arm if no second argument is provided

# --- Dynamic variable setup based on args ---
if [[ "$EL_VERSION" != "9" && "$EL_VERSION" != "10" ]]; then
  echo "Error: Invalid EL version '${EL_VERSION}'. Please use 9 or 10."
  exit 1
fi

DAISY_WORKFLOW_BASE="./packagebuild/workflows/build_el${EL_VERSION}"

if [[ "$ARCH" == "arm" ]]; then
  MACHINE_TYPE="t2a-standard-1"
  IMAGE_ARCH="arm64"
  VM_ARCH_TAG="arm"
  DAISY_WORKFLOW="${DAISY_WORKFLOW_BASE}_arm64.wf.json"
  IMAGE_FAMILY="rhel-${EL_VERSION}-${IMAGE_ARCH}"
elif [[ "$ARCH" == "x86" ]]; then
  MACHINE_TYPE="e2-standard-2"
  VM_ARCH_TAG="x86"
  DAISY_WORKFLOW="${DAISY_WORKFLOW_BASE}.wf.json"
  IMAGE_FAMILY="rhel-${EL_VERSION}"
else
  echo "Error: Invalid architecture '${ARCH}'. Please use 'arm' or 'x86'."
  exit 1
fi

echo "--- Running test for EL${EL_VERSION} on ${ARCH} architecture ---"

PROJECT_ID="liamll-personal"
ZONE="us-central1-b"
IMAGE_PROJECT="bct-prod-images"
REPO_OWNER="lpleahy"
REPO_NAME="guest-diskexpand"

GIT_BRANCH="master"
# --- Dynamically fetch the latest commit hash ---
echo "--- Fetching latest commit hash for ${REPO_OWNER}/${REPO_NAME} on branch ${GIT_BRANCH} ---"
if ! command -v git &>/dev/null; then
  echo "Error: 'git' command not found. Please install git to proceed."
  exit 1
fi
GIT_REF=$(git ls-remote "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "refs/heads/${GIT_BRANCH}" | cut -f1)
if [ -z "${GIT_REF}" ]; then
  echo "Error: Could not fetch latest commit hash. Check repository details and network connection."
  exit 1
fi
echo "Using commit hash: ${GIT_REF}"

# Generate a unique ID for this test run
ID_PREFIX=$(date +%Y%m%d)
TIME_SUFFIX=$(date +%H%M%S)
UNIQUE_ID="${ID_PREFIX}.${TIME_SUFFIX}"
VM_NAME="rhel${EL_VERSION}-${VM_ARCH_TAG}-expand-test-${ID_PREFIX}-${TIME_SUFFIX}" # Unique VM name
SENTINEL_FILE="/tmp/startup_script_complete.sentinel"

# --- Step 1: Build the RPM package with Daisy ---
echo "--- Step 1: Building RPM package for ${REPO_NAME} at ref ${GIT_REF} ---"
# Capture Daisy output to a variable and also print it to the console
DAISY_OUTPUT=$(daisy -project ${PROJECT_ID} -zone ${ZONE} \
  -var:git_ref="${GIT_REF}" \
  -var:repo_owner="${REPO_OWNER}" \
  -var:repo_name="${REPO_NAME}" \
  -var:version="${UNIQUE_ID}" \
  -var:gcs_path="gs://liamll-personal-guest-package-builder-daisy-bkt" \
  -var:sbom_util_gcs_root="gs://liamll-personal-sbom" \
  -var:build_dir="" \
  "${DAISY_WORKFLOW}" 2>&1 | tee /dev/tty)

if [ ${PIPESTATUS[0]} -ne 0 ]; then
  echo "Daisy build failed. Exiting."
  exit 1
fi

# --- Step 2: Parse the Daisy output to find the RPM's GS path ---
echo -e "\n--- Step 2: Parsing build output to find RPM path ---"
BASE_GCS_PATH=$(echo "${DAISY_OUTPUT}" | grep 'Daisy scratch path' | sed -n 's|.*storage/browser/\(.*\)|gs://\1|p')
BUILD_SUBDIR=$(echo "${DAISY_OUTPUT}" | grep 'Streaming instance' | sed -n 's|.*/\([^/]*\)/logs/.*|\1|p')
RPM_FILENAME=$(echo "${DAISY_OUTPUT}" | grep 'SuccessMatch found' | sed -n 's|.* \(/usr/src/redhat/RPMS/noarch/[^ ]*.rpm\).*|\1|p' | xargs basename)

if [ -z "${RPM_FILENAME}" ]; then
  echo "Error: Could not find RPM filename in Daisy output. The build may have failed."
  exit 1
fi

if [ -z "${BASE_GCS_PATH}" ] || [ -z "${BUILD_SUBDIR}" ] || [ -z "${RPM_FILENAME}" ]; then
  echo "Error: Could not parse RPM path from Daisy output."
  exit 1
fi
RPM_GS_PATH="${BASE_GCS_PATH}/${BUILD_SUBDIR}/outs/${RPM_FILENAME}"
echo "Successfully found RPM at: ${RPM_GS_PATH}"

# --- Step 3: Create VM with a startup script to install the RPM ---
echo -e "\n--- Step 3: Creating VM '${VM_NAME}' and installing RPM ---"

# Define the startup script that will run on the new VM
STARTUP_SCRIPT=$(
  cat <<EOF
#!/bin/bash
set -e
set -x
# Download the RPM from GCS
gsutil cp "${RPM_GS_PATH}" /tmp/gce-disk-expand.rpm
# Remove any existing version of the package to ensure a clean install
rpm -e gce-disk-expand || true
# Install the new RPM
dnf install -y /tmp/gce-disk-expand.rpm
# Create a sentinel file to signal that the script is done
touch "${SENTINEL_FILE}"
EOF
)

gcloud compute instances create "${VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type="${MACHINE_TYPE}" \
  --image-family="${IMAGE_FAMILY}" \
  --image-project="${IMAGE_PROJECT}" \
  --boot-disk-size=20GB \
  --metadata=startup-script="$STARTUP_SCRIPT"

# --- Step 4: Wait for the startup script to complete ---
echo -e "\n--- Step 4: Waiting for startup script on '${VM_NAME}' to complete ---"
TIMEOUT=600 # 10 minutes
INTERVAL=15
ELAPSED=0
SSH_NAME="nic0.${VM_NAME}.${ZONE}.c.liamll-personal.internal.gcpnode.com"
# nic0.centos-stream-10-arm-test-1.us-central1-f.c.liamll-personal.internal.gcpnode.com
while ! gcloud compute ssh "${VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" --command="test -f ${SENTINEL_FILE}" -- -o "Hostname=${SSH_NAME}" 2>/dev/null; do
  if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
    echo "Timeout waiting for startup script to complete."
    exit 1
  fi
  echo "Waiting... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo "Startup script completed successfully."

# --- Step 5: Resize disk, restart VM, and verify expansion ---
echo -e "\n--- Step 5: Resizing disk to 100GB and restarting VM ---"
gcloud compute disks resize "${VM_NAME}" --size=100GB --zone="${ZONE}" --quiet

echo "Stopping instance..."
gcloud compute instances stop "${VM_NAME}" --zone="${ZONE}"
echo "Starting instance..."
gcloud compute instances start "${VM_NAME}" --zone="${ZONE}"

echo "Waiting for VM to boot... (60 seconds)"
sleep 60

echo -e "\n--- Final Verification ---"
# SSH into the machine and run a script to gather all necessary info.
# We use a heredoc (<< 'EOF') to pass the script to the remote machine's
# standard input. This is much more robust than using the --command flag
# for multi-line scripts as it avoids complex shell escaping issues.
# The -T flag for ssh disables pseudo-terminal allocation, which is
# appropriate for non-interactive scripts and silences a common warning.
VERIFICATION_OUTPUT=$(
  gcloud compute ssh "${VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" -- -T -o "Hostname=${SSH_NAME}" <<'EOF'
    set -e
    # Get root partition device (e.g., /dev/sda2)
    ROOT_PARTITION=$(findmnt -n -o SOURCE /)
    # Get filesystem size in Gigabytes (integer only)
    FS_SIZE_GB=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
    # Get partition size in Gigabytes (integer only), using printf for robust parsing.
    PART_SIZE_GB=$(lsblk -b -o SIZE -n $ROOT_PARTITION | awk '{printf "%.0f", $1/1024/1024/1024}')

    # Print values for parsing later
    echo "FS_SIZE_GB=${FS_SIZE_GB}"
    echo "PART_SIZE_GB=${PART_SIZE_GB}"

    echo '--- Filesystem Usage (df -h) ---'
    df -h /
    echo '--- Block Device Layout (lsblk) ---'
    lsblk
    echo '--- Disk Expand Service Logs ---'
    journalctl -k | grep gce-disk-expand
EOF
)

# Print the full output for context
echo "${VERIFICATION_OUTPUT}"

# Extract the specific values needed for the check
FS_SIZE=$(echo "${VERIFICATION_OUTPUT}" | grep 'FS_SIZE_GB=' | cut -d'=' -f2)
PART_SIZE=$(echo "${VERIFICATION_OUTPUT}" | grep 'PART_SIZE_GB=' | cut -d'=' -f2)

# Check if the sizes are greater than 90GB (allowing for overhead on a 100G disk)
if [[ "$FS_SIZE" -gt 90 && "$PART_SIZE" -gt 90 ]]; then
  echo -e "\n\n--- ✅ VERIFICATION SUCCESS: Filesystem and partition correctly expanded to ~100G. ---"
else
  echo -e "\n\n--- ❌ VERIFICATION FAILURE: Filesystem or partition did not expand correctly. ---"
  echo "Expected size > 90G. Got Filesystem=${FS_SIZE}G, Partition=${PART_SIZE}G."
  exit 1
fi

# --- Step 6: Cleanup ---
echo -e "\n--- Step 6: Deleting test VM '${VM_NAME}' ---"
gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet

echo -e "\n--- Test complete ---"
