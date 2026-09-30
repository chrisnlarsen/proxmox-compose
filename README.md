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
| `volumes` | Mount points, see [Volumes](#volumes) |
| `depends_on` (list or `condition: service_started / service_healthy / service_completed_successfully`) | Services are created, started and updated in dependency order, waiting for each condition; PVE boot order (`startup: order=N`, with an `up` delay after services others depend on) follows the same order |
| `healthcheck` (`CMD` / `CMD-SHELL`, `interval`, `timeout`, `retries`, `start_period`) | Run inside the container with `pct exec` (with the container's environment) to wait for `service_healthy`. If a dependency never becomes healthy, the dependent service is started anyway with a warning |
| `x-pmxc: {cores, memory, swap, rootfs_size, vmid, ip}` | Proxmox-specific overrides per service (memory in MB, rootfs in GB; `ip` with or without `/prefix`) |
| `container_name` | Extra name for the service in the project hosts file |

### Volumes

| Compose volume | Becomes |
|---|---|
| Absolute path that exists on the host (`/srv/app:/data`) | A bind mount of that path |
| Absolute path that doesn't exist | An error before anything is created |
| `/var/run/docker.sock` | Skipped (no Docker on a Proxmox host) |
| Relative path or named volume used by **one** service (`./data:/data`, `db:/var/lib/db`) | A PVE volume on `volume_storage` (included in container backups) |
| Relative path or named volume used by **several** services | A host directory under `x-pmxc.data_dir` (default `<project>/volumes/<name>`) bind-mounted into each; owned by the first non-root container user so all of them can write |

`:ro` / `read_only: true` make the mount read-only. On update, mount points the container already has are kept; volumes new in the compose file are added the same way.

### Networking and service names

Each service gets its own container and address. With static addressing, the first service gets the configured address and each further service the next free one (or its own `x-pmxc.ip`); VMIDs count up the same way (or use `x-pmxc.vmid`). Addresses and VMIDs already used by other guests are refused.

Services reach each other by name like in Docker: the project gets a `hosts` file (`<service>` and `container_name` → address) that is bind-mounted read-only over `/etc/hosts` in every container. This needs static addressing; with DHCP, services can't resolve each other.

### Project settings (`x-pmxc`) and non-interactive installs

A top-level `x-pmxc` block pre-answers the installer's questions, which also allows unattended installs:

```yaml
x-pmxc:
  node: pve
  template_storage: local
  rootfs_storage: local-zfs
  volume_storage: local-zfs   # default: rootfs_storage
  volume_size: 8G             # default: 16G
  bridge: vmbr1
  tag: 50                     # VLAN tag (optional)
  ip: 10.10.50.40/24          # first service, or "dhcp"
  gateway: 10.10.50.1
  vmid: 940                   # first VMID (default: next free)
```

```bash
./proxmox-compose.sh install ./docker-compose.yml -y
```

With `-y` nothing is asked: missing required settings are an error, and a failed install removes the containers it created.

A local compose file's `.env` and `env_file` files are copied into the project; for a URL, the installer offers to edit `.env` if variables are missing.

## Limitations & Known Issues

*   **OCI Extraction Errors**: Some images (e.g., `postgres:14-alpine`, some `node` images) fail to extract on Proxmox/LXC due to hardlink handling on ZFS. This presents as `IO error: failed to unpack ... File exists`.
    *   *Workaround*: Try using a different base image (e.g., `debian`) or wait for upstream Proxmox fixes.
*   **Restart Policies**: Does not currently map `restart` policies to Proxmox startup options.
*   **Ignored**: `ports` (each container has its own IP), `networks`, `labels`, image `HEALTHCHECK` instructions (only compose healthchecks are used).
*   **Project directory permissions**: the hosts file and shared volumes are bind-mounted into unprivileged containers, so every directory above them must be world-traversable (the default `/var/lib/proxmox-compose` is). The installer checks this.
*   **Unknown build image**: if a container's original template is no longer on disk, the update can't tell image defaults from customisations. It keeps the entrypoint and init user/cwd as they are, lets the new image set the environment variables it defines, and lists the ones it replaced.
*   **Deleting a project and keeping data**: PVE deletes every volume a container owns when it is destroyed, so "keep data" leaves the containers stopped (tagged `pmxc-detached`, onboot off) instead of destroying them.

## Disclaimer

**Not affiliated with Proxmox Server Solutions GmbH.**
This is a community project created to explore OCI container orchestration on Proxmox VE. Use at your own risk.

**AI-Assisted Creation**
This software was developed with the assistance of advanced AI coding agents. While verified for functionality, please review the code before running it in production environments.

## License

MIT License. See [LICENSE](LICENSE) for details.
