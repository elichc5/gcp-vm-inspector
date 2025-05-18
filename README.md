# gcp-vm-inspector

A Bash utility to collect detailed, hierarchical information about a Google Compute Engine VM and generate a structured text report.

## Features

- Extracts project ID, instance name, and zone.
- Reports machine type, vCPUs, memory (GB), and operating system.
- Retrieves network configuration: VPC, subnet, private and public IPs.
- Lists service account and firewall tags.
- Enumerates boot and attached disks (zonal and regional), showing size and type.
- Auto-generates `gcloud` commands for creating snapshots, images, and new disks.

## Requirements

- Bash (≥4.0)
- [gcloud CLI](https://cloud.google.com/sdk) (authenticated)
- [jq](https://stedolan.github.io/jq/) (for JSON parsing)
- [bc](https://www.gnu.org/software/bc/) (installed automatically if not present)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/<your-user>/gcp-vm-inspector.git
   cd gcp-vm-inspector


2. Make the script executable:

   ```bash
   chmod +x gather-vm-info.sh
   ```

## Usage

```bash
./gather-vm-info.sh <PROJECT_ID> <INSTANCE_NAME> <ZONE>
```

**Example**:

```bash
./gather-vm-info.sh my-project vm-example us-east1-b
```

This will create a file named `vm-example_YYYYMMDD_info.txt` containing the full report.

## License

MIT License © \Francisco Chaná
