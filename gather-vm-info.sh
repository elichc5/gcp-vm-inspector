#!/usr/bin/env bash

# -------------------------------------------------------------------
# Collect detailed information about a Google Compute Engine VM.
# Adjusted to handle both zonal and regional disks without exiting
# when encountering a regional resource.
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
# -------------------------------------------------------------------

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <PROJECT_ID> <INSTANCE_NAME> <ZONE>"
  exit 1
fi

PROJECT_ID="$1"
INSTANCE_NAME="$2"
ZONE="$3"

# -------------------------------------------------------------------
# Ensure 'bc' is installed
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# Redirect all output to the report file
# -------------------------------------------------------------------
{
  echo "=========================================================="
  echo "        VM Report: ${INSTANCE_NAME}"
  echo "        Project: ${PROJECT_ID}"
  echo "        Zone:    ${ZONE}"
  echo "        Run Date: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================================="
  echo

  # -----------------------------------------------------------------
  # 1) Fetch instance metadata as JSON
  # -----------------------------------------------------------------
  instance_json=$(gcloud compute instances describe "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --format=json)

  # -----------------------------------------------------------------
  # 2) Machine type and resources (vCPUs, memory)
  # -----------------------------------------------------------------
  MACHINE_TYPE_FULL=$(jq -r '.machineType' <<< "${instance_json}")
  MACHINE_TYPE=$(basename "${MACHINE_TYPE_FULL}")
  mt_json=$(gcloud compute machine-types describe "${MACHINE_TYPE}" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --format=json)
  VCPUS=$(jq -r '.guestCpus' <<< "${mt_json}")
  MEM_MB=$(jq -r '.memoryMb' <<< "${mt_json}")
  MEM_GB=$(echo "scale=2; ${MEM_MB}/1024" | bc)

  echo "==> Machine Type: ${MACHINE_TYPE}"
  echo "    - vCPUs:        ${VCPUS}"
  echo "    - Memory (GB):  ${MEM_GB}"
  echo

  # -----------------------------------------------------------------
  # 3) Operating system (from boot disk license)
  # -----------------------------------------------------------------
  OS_LICENSE=$(jq -r '.disks[] | select(.boot==true) | .licenses[]?' <<< "${instance_json}" | tail -n1)
  OS_NAME=$(basename "${OS_LICENSE:-unknown}")
  echo "==> Operating System: ${OS_NAME}"
  echo

  # -----------------------------------------------------------------
  # 4) Network details
  # -----------------------------------------------------------------
  NIC_JSON=$(jq -r '.networkInterfaces[0]' <<< "${instance_json}")
  NETWORK_NAME=$(basename "$(jq -r '.network' <<< "${NIC_JSON}")")
  SUBNET_NAME=$(basename "$(jq -r '.subnetwork' <<< "${NIC_JSON}")")
  INTERNAL_IP=$(jq -r '.networkIP' <<< "${NIC_JSON}")
  EXTERNAL_IP=$(jq -r '.accessConfigs[0].natIP? // "None"' <<< "${NIC_JSON}")

  echo "==> Network and Subnet:"
  echo "    - VPC Network: ${NETWORK_NAME}"
  echo "    - Subnet:      ${SUBNET_NAME}"
  echo "    - Internal IP: ${INTERNAL_IP}"
  echo "    - External IP: ${EXTERNAL_IP}"
  echo

  # -----------------------------------------------------------------
  # 5) Service account attached to the VM
  # -----------------------------------------------------------------
  SERVICE_ACCOUNT=$(jq -r '.serviceAccounts[0].email' <<< "${instance_json}")
  echo "==> Service Account: ${SERVICE_ACCOUNT}"
  echo

  # -----------------------------------------------------------------
  # 6) Firewall tags
  # -----------------------------------------------------------------
  TAGS=$(jq -r '.tags.items | if length>0 then join(",") else "None" end' <<< "${instance_json}")
  echo "==> Firewall Tags: ${TAGS}"
  echo

  # -----------------------------------------------------------------
  # 7) Commands for disks (boot and attached)
  # -----------------------------------------------------------------
  echo "==> Attached Disks:"
  mapfile -t DISKS < <(jq -r '.disks[] | @base64' <<< "${instance_json}")

  if [ ${#DISKS[@]} -eq 0 ]; then
    echo "    None"
    echo
  else
    for d in "${DISKS[@]}"; do
      disk_json=$(echo "$d" | base64 --decode)
      boot=$(jq -r '.boot' <<< "$disk_json")
      src=$(jq -r '.source' <<< "$disk_json")
      name=$(basename "$src")
      label="Attached Disk"
      [ "$boot" = "true" ] && label="Boot Disk"
      echo "  -> ${label}:"
      echo "       * Name: ${name}"
      echo "       * URI:  ${src}"

      #
      # 7.1) Determine if disk is zonal or regional
      #
      if echo "$src" | grep -q "/regions/"; then
        region=$(echo "$src" | awk -F'/regions/' '{print $2}' | awk -F'/' '{print $1}')
        describe_flag="--region=${region}"
        snap_flag="--source-disk-region=${region}"
        storage_loc="${region}"

        echo "       * Type: Regional (region = ${region})"
      else
        zone_from_src=$(echo "$src" | awk -F'/zones/' '{print $2}' | awk -F'/' '{print $1}')
        describe_flag="--zone=${zone_from_src}"
        snap_flag="--source-disk-zone=${zone_from_src}"
        storage_loc="${zone_from_src%-*}"

        echo "       * Type: Zonal (zone = ${zone_from_src})"
      fi

      #
      # 7.2) Get disk size and type
      #      If the describe command fails, continue without exiting
      #
      if disk_info=$(gcloud compute disks describe "${name}" \
          --project="${PROJECT_ID}" ${describe_flag} --format="value(sizeGb,type)" 2>/dev/null); then
        size=$(echo "${disk_info}" | awk '{print $1}')
        type_full=$(echo "${disk_info}" | awk '{print $2}')
        disk_type=$(basename "${type_full}")
      else
        size="unknown"
        disk_type="unknown"
        echo "       ! Warning! Unable to describe disk '${name}'."
      fi

      echo "       * Size (GB):   ${size}"
      echo "       * Disk Type:   ${disk_type}"
      echo

      #
      # 7.3) Suggested commands for snapshot and image
      #
      snap_name="${name}-${DATE}"
      echo "       # Suggested commands:"
      echo "       # 1) Create Snapshot:"
      echo "            gcloud compute snapshots create ${snap_name} \\"
      echo "                --project=${PROJECT_ID} ${snap_flag} \\"
      echo "                --source-disk=${name} \\"
      echo "                --storage-location=${storage_loc}"
      echo
      echo "       # 2) Create Image from Snapshot:"
      echo "            gcloud compute images create ${snap_name} \\"
      echo "                --project=${PROJECT_ID} \\"
      echo "                --source-snapshot=${snap_name}"
      echo
      echo "       # 3) Create new Disk from Image:"
      echo "            gcloud compute disks create ${snap_name} \\"
      if echo "$src" | grep -q "/regions/"; then
        echo "                  --project=${PROJECT_ID} --region=${region} \\"
      else
        echo "                  --project=${PROJECT_ID} --zone=${zone_from_src} \\"
      fi
      echo "                    --image=${snap_name} \\"
      echo "                    --size=${size}GB \\"
      echo "                    --type=${disk_type}"
      echo
      echo "       # 4) Create new Disk from Snapshot:"
      echo "            gcloud compute disks create ${snap_name}-from-snapshot \\"
      if echo "$src" | grep -q "/regions/"; then
        echo "                  --project=${PROJECT_ID} --region=${region} \\"
      else
        echo "                  --project=${PROJECT_ID} --zone=${zone_from_src} \\"
      fi
      echo "                    --source-snapshot=${snap_name} \\"
      echo "                    --size=${size}GB \\"
      echo "                    --type=${disk_type}"
      echo

    done
  fi

  #
  # 8) Disk Summary
  #
  echo "==> Disk Summary:"
  # Extract boot disk name
  boot_disk=$(jq -r '.disks[] | select(.boot==true) | .source' <<< "${instance_json}" | xargs basename)
  if [ -n "${boot_disk}" ] && [ "${boot_disk}" != "null" ]; then
    echo "    - Boot disk: ${boot_disk}"
  else
    echo "    - Boot disk: None"
  fi

  # Extract all non-boot (data) disks
  data_disks=( $(jq -r '.disks[] | select(.boot==false) | .source' <<< "${instance_json}" | xargs -n1 basename) )
  if [ ${#data_disks[@]} -eq 0 ]; then
    echo "    - Data disks: None"
  else
    count=1
    for dd in "${data_disks[@]}"; do
      echo "    - Data disk ${count}: ${dd}"
      count=$((count + 1))
    done
  fi
  echo


  echo
  echo "----------------------------------------------------------"
  echo "    END OF REPORT"
  echo "----------------------------------------------------------"
} > "${OUTPUT_FILE}"

echo "✔️ VM information saved to: ${OUTPUT_FILE}"
