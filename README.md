# Proxmox OCI Composer

A shell utility to deploy `docker-compose.yml` services as native OCI-based LXC containers on Proxmox VE 9.1+.

## Prerequisites

*   **Proxmox VE 9.1** or later.
*   **Root Access**: The script must be run as root on the Proxmox host.
*   **Python 3**: Installed by default on Proxmox.
*   **Storage**: A storage configured to support "Container templates" (`vztmpl`) and OCI import.

## Installation

1.  Copy `proxmox-compose.sh` to your Proxmox host.
2.  Make it executable:
    ```bash
    chmod +x proxmox-compose.sh
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
*   **Environment Variables**: Parses `environment` sections and injects them into the container configuration (`lxc.environment`).
*   **Container Creation**: Automatically creates unprivileged LXC containers for each service.

## Limitations

*   **Restart Policies**: Does not currently map `restart` policies to Proxmox startup options.

## Troubleshooting

*   **Image Pull Fails**: If the script hangs or fails to pull, check if you can pull the image manually via the Proxmox GUI > Storage > CT Templates > Pull from OCI Registry.
*   **Template Not Found**: If the script cannot find the template after pulling, you may need to manually enter the path when prompted (e.g., `local:vztmpl/my-image.tar.zst`).
