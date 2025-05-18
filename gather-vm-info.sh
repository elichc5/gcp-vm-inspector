#!/usr/bin/env bash

# Collect detailed information about a Google Compute Engine VM
# Hierarchically extracts data and outputs to a .txt report
#
# Usage:
#   chmod +x gather-vm-info.sh
#   ./gather-vm-info.sh <PROJECT_ID> <INSTANCE_NAME> <ZONE>
# Example:
#   ./gather-vm-info.sh my-project vm-example us-east1-b
#
# Requirements:
#   - Authenticated gcloud CLI
#   - jq installed
#   - bc installed (will be auto-installed if possible)

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <PROJECT_ID> <INSTANCE_NAME> <ZONE>"
  exit 1
fi

PROJECT_ID="$1"
INSTANCE_NAME="$2"
ZONE="$3"

# Ensure bc is installed
if ! command -v bc >/dev/null; then
  echo "==> Installing 'bc'..."
  if command -v apt-get >/dev/null; then
    sudo apt-get update && sudo apt-get install -y bc
  elif command -v yum >/dev/null; then
    sudo yum install -y bc
  else
    echo "Please install 'bc' manually." >&2
    exit 1
  fi
fi

DATE=$(date +"%Y%m%d")
OUTPUT_FILE="${INSTANCE_NAME}_${DATE}_info.txt"

# Redirect all output to the report file
{
  echo "Project ID: ${PROJECT_ID}"
  echo "Instance Name: ${INSTANCE_NAME}"
  echo "Zone: ${ZONE}"
  echo

  # Fetch instance metadata as JSON
  instance_json=$(gcloud compute instances describe "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --format=json)

  # Machine type and resources
  MACHINE_TYPE_FULL=$(jq -r '.machineType' <<< "${instance_json}")
  MACHINE_TYPE=$(basename "${MACHINE_TYPE_FULL}")
  mt_json=$(gcloud compute machine-types describe "${MACHINE_TYPE}" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --format=json)
  VCPUS=$(jq -r '.guestCpus' <<< "${mt_json}")
  MEM_MB=$(jq -r '.memoryMb' <<< "${mt_json}")
  MEM_GB=$(echo "scale=2; ${MEM_MB}/1024" | bc)

  echo "Machine Type: ${MACHINE_TYPE}"
  echo "vCPUs: ${VCPUS}"
  echo "Memory (GB): ${MEM_GB}"
  echo

  # Operating system (from boot disk license)
  OS_LICENSE=$(jq -r '.disks[] | select(.boot==true) | .licenses[]?' <<< "${instance_json}" | tail -n1)
  OS_NAME=$(basename "${OS_LICENSE:-unknown}")
  echo "Operating System: ${OS_NAME}"
  echo

  # Network details
  NIC_JSON=$(jq -r '.networkInterfaces[0]' <<< "${instance_json}")
  NETWORK_NAME=$(basename "$(jq -r '.network' <<< "${NIC_JSON}")")
  SUBNET_NAME=$(basename "$(jq -r '.subnetwork' <<< "${NIC_JSON}")")
  INTERNAL_IP=$(jq -r '.networkIP' <<< "${NIC_JSON}")
  EXTERNAL_IP=$(jq -r '.accessConfigs[0].natIP? // "None"' <<< "${NIC_JSON}")

  echo "VPC Network: ${NETWORK_NAME}"
  echo "Subnet: ${SUBNET_NAME}"
  echo "Internal IP: ${INTERNAL_IP}"
  echo "External IP: ${EXTERNAL_IP}"
  echo

  # Service account
  SERVICE_ACCOUNT=$(jq -r '.serviceAccounts[0].email' <<< "${instance_json}")
  echo "Service Account: ${SERVICE_ACCOUNT}"
  echo

  # Firewall tags
  TAGS=$(jq -r '.tags.items | if length>0 then join(",") else "None" end' <<< "${instance_json}")
  echo "Firewall Tags: ${TAGS}"
  echo

  # Disks (boot and attached)
  echo "Disks:"
  mapfile -t DISKS < <(jq -r '.disks[] | @base64' <<< "${instance_json}")
  if [ ${#DISKS[@]} -eq 0 ]; then
    echo "  None"
    echo
  else
    for d in "${DISKS[@]}"; do
      disk_json=$(echo "$d" | base64 --decode)
      boot=$(jq -r '.boot' <<< "$disk_json")
      src=$(jq -r '.source' <<< "$disk_json")
      name=$(basename "$src")
      label="Attached Disk"
      [ "$boot" = "true" ] && label="Boot Disk"
      echo "  ${label}:"
      echo "    Name: ${name}"

      # Determine if disk is zonal or regional
      if [[ "$src" == *"/regions/"* ]]; then
        region=$(awk -F/ '{print $5}' <<< "$src")
        describe_opt="--region=${region}"
        snap_flag="--source-disk-region=${region}"
        storage_loc="${region}"
      else
        describe_opt="--zone=${ZONE}"
        snap_flag="--source-disk-zone=${ZONE}"
        storage_loc="${ZONE%-*}"
      fi

      # Disk size and type
      dt=$(gcloud compute disks describe "$name" \
        --project="${PROJECT_ID}" ${describe_opt} --format="value(sizeGb,type)")
      size=$(echo "$dt" | awk '{print $1}')
      type_full=$(echo "$dt" | awk '{print $2}')
      disk_type=$(basename "$type_full")
      echo "    Size (GB): ${size}"
      echo "    Type: ${disk_type}"
      echo

      # Snapshot, image, and recreate commands
      snap_name="${name}-${DATE}"
      echo "    # Snapshot: gcloud compute snapshots create ${snap_name} --project=${PROJECT_ID} ${snap_flag} --source-disk=${name} --storage-location=${storage_loc}"
      echo "    # Image: gcloud compute images create ${snap_name} --project=${PROJECT_ID} --source-snapshot=${snap_name}"
      echo "    # Create Disk from Image: gcloud compute disks create ${snap_name}-from-image --project=${PROJECT_ID} ${describe_opt} --image=${snap_name} --size=${size}GB --type=${disk_type}"
      echo "    # Create Disk from Snapshot: gcloud compute disks create ${snap_name}-from-snapshot --project=${PROJECT_ID} ${describe_opt} --source-snapshot=${snap_name} --size=${size}GB --type=${disk_type}"
      echo
    done
  fi

} > "${OUTPUT_FILE}"

echo "VM information saved to ${OUTPUT_FILE}"
