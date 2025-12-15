# Proxmox OCI Composer

A shell utility to deploy `docker-compose.yml` services as native OCI-based LXC containers on Proxmox VE 9.1+.

## Prerequisites

*   **Proxmox VE 9.1** or later.
*   **Root Access**: The script must be run as root on the Proxmox host.
*   **Python 3**: Installed by default on Proxmox.
*   **Storage**: A storage configured to support "Container templates" (`vztmpl`) and OCI import.

## Installation

Run the following command on your Proxmox host:

```bash
bash -c "$(curl -fsSL https://github.com/chrisnlarsen/proxmox-compose/raw/refs/heads/main/proxmox-compose.sh)"
```

Alternatively, you can manually download `proxmox-compose.sh` and run it:

```bash
chmod +x proxmox-compose.sh
./proxmox-compose.sh
```

## Usage

1.  Navigate to a directory containing your `docker-compose.yml`.
2.  Run the script:
    ```bash
    ./proxmox-compose.sh
    ```
3.  Follow the interactive prompts:
    *   **Target Node**: Select the node (if clustered).
    *   **Target Template Storage**: Select storage for downloading OCI images (must support `vztmpl`).
    *   **Target Container Storage**: Select storage for the container disks (must support `rootdir`, e.g., `local-zfs`).
    *   **Target Volume Storage**: Select storage for persistent volumes (e.g., `local-zfs`).
    *   **Volume Size**: Default size for new volumes (e.g., `16G`). **Note**: Safe to oversize on thin-provisioned storage.
    *   **Network Bridge**: Select the bridge (auto-detected list, e.g., `vmbr0`).
    *   **IP Configuration**: Choose `dhcp` or `static`.
        *   If `static`: Enter CIDR (e.g., `192.168.1.10/24`) and Gateway.
    *   **Starting VMID**: Confirm the starting ID for the new containers.

## Features

*   **Automatic Image Pulling**: Uses Proxmox API (`pvesh`) to pull OCI images from the registry defined in your compose file.
*   **Advanced Networking**: Auto-detects available bridges from `/etc/network/interfaces`. Supports both DHCP and Static IP configuration per deployment.
*   **Persistent Volumes**: Supports standard bindings (`./data:/data`) and global named volumes. Automatically allocates virtual disks on Proxmox storage and attaches them to containers.
*   **Update Workflow**: **New!** Includes a "Update Project" option to safely detach persistent volumes, destroy only the container, pull the latest image, and re-deploy while preserving your data.
*   **Environment Variables**: Parses `environment` sections and injects them into the container configuration (`lxc.environment`).
*   **Container Creation**: Automatically creates unprivileged LXC containers for each service.

## Limitations & Known Issues

*   **OCI Extraction Errors**: Some images (e.g., `postgres:14-alpine`, some `node` images) fail to extract on Proxmox/LXC due to hardlink handling on ZFS. This presents as `IO error: failed to unpack ... File exists`.
    *   *Workaround*: Try using a different base image (e.g., `debian`) or wait for upstream Proxmox fixes.
*   **Restart Policies**: Does not currently map `restart` policies to Proxmox startup options.

## Disclaimer

**Not affiliated with Proxmox Server Solutions GmbH.**
This is a community project created to explore OCI container orchestration on Proxmox VE. Use at your own risk.

**AI-Assisted Creation**
This software was developed with the assistance of advanced AI coding agents. While verified for functionality, please review the code before running it in production environments.

## License

MIT License. See [LICENSE](LICENSE) for details.
