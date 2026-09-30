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

### Updating a project

From the menu choose **Manage Projects → Update Project**, or run it non-interactively (e.g. from cron):

```bash
./proxmox-compose.sh list                 # show projects
./proxmox-compose.sh update <project>     # prompts for confirmation
./proxmox-compose.sh update <project> -y  # no prompts; uses the local compose file
```

For each service the update:

1. Pulls the image to a new, timestamped template (so `:latest` really is re-pulled) and creates a staging container from it. If either fails, nothing has been touched.
2. Stops the service and moves its data volumes onto the staging container (`pct move-volume`).
3. Destroys the old container **without** `--purge` (it stays in backup jobs/HA) and recreates it from the new image under the **same VMID**.
4. Restores network config (MAC/IP), cores, memory, swap, tags, description, features, bind mounts and the container firewall rules, and moves the data volumes back.
5. Carries over runtime customisations. PVE generates `entrypoint`, the environment and `lxc.init.*` (user/working dir) from the image when a container is created and stores them in `<vmid>.conf`. The update compares the container's values with what PVE would have generated from the image it was built from (recorded in `metadata.json` as `template`): customised values are kept (e.g. `entrypoint: dumb-init -- ak worker`), everything else follows the new image, and the compose `environment` is applied on top. If the image changed its own default entrypoint while you have a custom one, the update warns you.
6. Starts the service if it was running, removes the staging container and deletes old templates for that image (keeping the current and previous one).

The previous container config (and firewall rules) are saved in the project directory as `<vmid>-<timestamp>.conf.bak` / `.fw.bak`.

An update refuses to start for a container that has **snapshots** (PVE cannot move volumes used by a snapshot), **pending config changes**, or **protection** enabled.

## Features

*   **Automatic Image Pulling**: Uses Proxmox API (`pvesh`) to pull OCI images from the registry defined in your compose file.
*   **Advanced Networking**: Auto-detects available bridges from `/etc/network/interfaces`. Supports both DHCP and Static IP configuration per deployment.
*   **Persistent Volumes**: Supports standard bindings (`./data:/data`) and global named volumes. Automatically allocates virtual disks on Proxmox storage and attaches them to containers.
*   **Update Workflow**: Rebuilds each container from a freshly pulled image under the same VMID while moving (never deleting) its data volumes. See [Updating a project](#updating-a-project).
*   **Environment Variables**: Parses `environment` sections and injects them into the container configuration (`lxc.environment`).
*   **Container Creation**: Automatically creates unprivileged LXC containers for each service.

## Compose support

| Compose key | Becomes |
|---|---|
| `image` | OCI image pulled into a template (`pvesh .../oci-registry-pull`) |
| `.env`, `${VAR}`, `${VAR:-default}`, `${VAR:?error}`, `${VAR:+alt}`, `$$` | Interpolated everywhere; the shell environment overrides `.env`. A missing required variable stops before anything is changed. |
| `env_file`, `environment` | The container environment (image defaults + env files + `environment`) |
| `command`, `entrypoint` | The container `entrypoint` (combined with the image's Entrypoint/Cmd the way Docker does) |
| `user` | `lxc.init.uid` / `lxc.init.gid` (numeric or `root`) |
| `shm_size` | A sized tmpfs on `/dev/shm` |
| `restart` | `onboot` (`no` → off, anything else → on) |
| `mem_limit`, `cpus`, `deploy.resources.limits` | `memory`, `cores` |
| `volumes` | Container volumes (see Features) |
| `x-pmxc: {cores, memory, swap, rootfs_size}` | Proxmox-specific overrides per service (memory in MB, rootfs in GB) |

A local compose file's `.env` and `env_file` files are copied into the project; for a URL, the installer offers to edit `.env` if variables are missing.

## Limitations & Known Issues

*   **OCI Extraction Errors**: Some images (e.g., `postgres:14-alpine`, some `node` images) fail to extract on Proxmox/LXC due to hardlink handling on ZFS. This presents as `IO error: failed to unpack ... File exists`.
    *   *Workaround*: Try using a different base image (e.g., `debian`) or wait for upstream Proxmox fixes.
*   **Restart Policies**: Does not currently map `restart` policies to Proxmox startup options.
*   **Not supported yet**: `depends_on`/`healthcheck` ordering, service-name DNS between services, per-service IPs (all services of a project currently share the configured network settings), and volumes shared between services. `ports` are ignored (each container has its own IP).
*   **Unknown build image**: if a container's original template is no longer on disk, the update can't tell image defaults from customisations. It keeps the entrypoint and init user/cwd as they are, lets the new image set the environment variables it defines, and lists the ones it replaced.
*   **Deleting a project and keeping data**: PVE deletes every volume a container owns when it is destroyed, so "keep data" leaves the containers stopped (tagged `pmxc-detached`, onboot off) instead of destroying them.

## Disclaimer

**Not affiliated with Proxmox Server Solutions GmbH.**
This is a community project created to explore OCI container orchestration on Proxmox VE. Use at your own risk.

**AI-Assisted Creation**
This software was developed with the assistance of advanced AI coding agents. While verified for functionality, please review the code before running it in production environments.

## License

MIT License. See [LICENSE](LICENSE) for details.
