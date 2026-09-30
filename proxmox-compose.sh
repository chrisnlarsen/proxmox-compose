#!/bin/bash

# Proxmox OCI Composer
# Reads a docker-compose.yml file and deploys services as OCI-based LXC containers on Proxmox VE 9.1+

# set -e


# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

PMXC_VERSION="0.4"
# PMXC_BASE_DIR can be overridden (e.g. for testing against a scratch directory)
PROJECT_BASE_DIR="${PMXC_BASE_DIR:-/var/lib/proxmox-compose}"
# Temp dir for initial download
TMP_DIR=$(mktemp -d /tmp/proxmox-compose.XXXXXX)
PROJECT_DIR=""
METADATA_FILE=""
created_vmids=()
# Set by update_service when volumes are parked on a staging container, so a
# failure never destroys the only copy of a project's data.
PARKED_VOLUMES_ON=""

# Error handling and rollback
cleanup_on_error() {
    local exit_code=$?
    # Only run rollback if we have created VMs and exit was not clean
    if [ $exit_code -ne 0 ] && [ ${#created_vmids[@]} -gt 0 ]; then
        echo ""
        tui_msg "Installation Failed!"
        if tui_yesno "Installation failed. Rollback/Cleanup created containers (${created_vmids[*]})?"; then
            echo "Rolling back..."
            for vmid in "${created_vmids[@]}"; do
                echo "Destroying incomplete container $vmid..."
                pct stop $vmid 2>/dev/null || true
                pct destroy $vmid --purge 2>/dev/null || true
            done
            tui_msg "Rollback complete."
        else
            echo "Skipping rollback."
        fi
    fi
    if [ -n "$PARKED_VOLUMES_ON" ]; then
        echo ""
        echo "WARNING: Update did not finish. Data volumes are parked on staging container $PARKED_VOLUMES_ON."
        echo "They have NOT been deleted. See 'pct config $PARKED_VOLUMES_ON' and move them back with:"
        echo "  pct move-volume $PARKED_VOLUMES_ON mpN --target-vmid <vmid> --target-volume mpN"
    fi
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap 'cleanup_on_error' EXIT

# Ensure base dir exists
mkdir -p "$PROJECT_BASE_DIR"

echo "Proxmox OCI Composer"
echo "===================="

# --- Dependencies & TUI Helpers ---

check_dependencies() {
    local deps=("whiptail" "python3" "curl" "pct" "pvesh" "pvesm")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Required dependency '$cmd' is missing."
            exit 1
        fi
    done
}

# TUI Wrappers
tui_msg() {
    whiptail --title "Proxmox Compose" --msgbox "$1" 10 60
}

tui_yesno() {
    if whiptail --title "Proxmox Compose" --yesno "$1" 10 60; then
        return 0
    else
        return 1
    fi
}

tui_input() {
    # $1=prompt, $2=default, $3=variable_name
    local val
    val=$(whiptail --title "Proxmox Compose" --inputbox "$1" 10 60 "$2" 3>&1 1>&2 2>&3)
    # Return 1 if cancelled (check whiptail's status, not the assignment's)
    if [ $? -ne 0 ]; then return 1; fi
    printf -v "$3" '%s' "$val"
}

tui_menu() {
    # $1=text, $2=height, $3=width, $4=menu-height, $5+ = options
    # Output to stdout (capture it)
    whiptail --title "Proxmox Compose" --menu "$1" "$2" "$3" "$4" "${@:5}" 3>&1 1>&2 2>&3
}

check_dependencies


# --- Embedded Python Parser ---
# Parses docker-compose.yml and outputs a JSON-like structure
# Output format per line (tab separated, JSON never contains raw tabs):
# SERVICE_NAME<TAB>IMAGE<TAB>ENV_VARS_JSON<TAB>VOLUMES_JSON
parse_compose() {
    python3 -c '
import yaml
import sys
import json

try:
    with open(sys.argv[1], "r") as f:
        data = yaml.safe_load(f)

    if not data or "services" not in data:
        print("Error: No services found in compose file", file=sys.stderr)
        sys.exit(1)

    for name, service in data["services"].items():
        image = service.get("image")
        if not image:
            print(f"Warning: Service {name} has no image defined. Skipping.", file=sys.stderr)
            continue
        
        # Handle environment variables (list or dict)
        env = {}
        raw_env = service.get("environment")
        if isinstance(raw_env, list):
            for item in raw_env:
                if "=" in item:
                    k, v = item.split("=", 1)
                    env[k] = v
                else: 
                     # Handle "KEY" (pass-through) - simplistic check
                     pass 
        if isinstance(raw_env, dict):
            env = raw_env
        
        # Handle volumes
        volumes = []
        raw_vols = service.get("volumes", [])
        for v in raw_vols:
            # v might be "source:target" or "source:target:mode"
            # or dict (long syntax)
            if isinstance(v, str):
                parts = v.split(":")
                source = parts[0]
                target = parts[1] if len(parts) > 1 else source # Fallback
                
                # Determine type
                # If source starts with ./ or / or ~, it is a bind mount (local path) -> We treat as NEW volume
                # If source is named (alphanumeric), it is a global volume
                v_type = "bind"
                if not (source.startswith(".") or source.startswith("/") or source.startswith("~")):
                    v_type = "global"
                
                volumes.append({"type": v_type, "source": source, "target": target})
            elif isinstance(v, dict):
                # Long syntax not fully supported yet, best effort
                source = v.get("source")
                target = v.get("target")
                v_type = "bind" if v.get("type") == "bind" else "global"
                if source and target:
                     volumes.append({"type": v_type, "source": source, "target": target})

        print(f"{name}\t{image}\t{json.dumps(env)}\t{json.dumps(volumes)}")

except Exception as e:
    print(f"Error parsing yaml: {e}", file=sys.stderr)
    sys.exit(1)
' "$COMPOSE_FILE"
}

# --- Utils ---

# Function to get next available VMID
get_next_vmid() {
    local next_id=$(pvesh get /cluster/nextid)
    echo "$next_id"
}

# Template filename prefix for an image, e.g. huntarr/huntarr:latest -> pmxc_huntarr_huntarr_latest
_template_prefix() {
    printf 'pmxc_%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9.-' '_')"
}

# List template volids for an image: versioned (pmxc_<image>_<date>.tar) and
# the legacy unversioned name (pmxc_<image>.tar).
_list_templates() {
    local prefix_re
    prefix_re=$(_template_prefix "$1" | sed 's/[.]/\\./g')
    pvesm list "$TEMPLATE_STORAGE" --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' \
        | grep -E "^$TEMPLATE_STORAGE:vztmpl/${prefix_re}(_[0-9]{8}-[0-9]{6})?\.tar$"
}

# Pull an OCI image to a *versioned* template file so repeat pulls actually
# fetch the current image (a fixed filename makes PVE refuse to overwrite it).
# Sets TEMPLATE_VOLID on success. Returns 1 on failure.
_pull_image() {
    local image="$1"
    local base="$(_template_prefix "$image")_$(date +%Y%m%d-%H%M%S)"
    TEMPLATE_VOLID=""

    echo "Pulling image '$image' to $TEMPLATE_STORAGE on $TARGET_NODE as '$base.tar'..."
    local out upid status exit_status
    out=$(pvesh create /nodes/$TARGET_NODE/storage/$TEMPLATE_STORAGE/oci-registry-pull --reference "$image" --filename "$base" 2>&1)
    upid=$(echo "$out" | grep -o "UPID:.*" | tail -n 1)
    if [ -z "$upid" ]; then
        echo "Error: Could not start image pull."
        echo "$out"
        return 1
    fi

    echo "Pull task started: $upid"
    while true; do
        status=$(pvesh get /nodes/$TARGET_NODE/tasks/$upid/status --output-format json 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", "unknown"))' 2>/dev/null || echo "unknown")
        if [ "$status" = "stopped" ]; then break; fi
        sleep 2
    done
    exit_status=$(pvesh get /nodes/$TARGET_NODE/tasks/$upid/status --output-format json | python3 -c 'import sys, json; print(json.load(sys.stdin).get("exitstatus", "unknown"))')
    if [ "$exit_status" != "OK" ]; then
        echo "Error: Image pull failed. Exit status: $exit_status"
        return 1
    fi

    TEMPLATE_VOLID="$TEMPLATE_STORAGE:vztmpl/$base.tar"
    echo "Image pulled successfully: $TEMPLATE_VOLID"
}

# Delete old templates for an image, keeping the given volids (current + previous).
_prune_templates() {
    local image="$1"; shift
    local volid keep k
    while read -r volid; do
        [ -z "$volid" ] && continue
        keep="false"
        for k in "$@"; do [ "$volid" = "$k" ] && keep="true"; done
        if [ "$keep" = "false" ]; then
            echo "Removing old template $volid"
            pvesm free "$volid" >/dev/null 2>&1 || echo "Warning: could not remove $volid"
        fi
    done < <(_list_templates "$image")
}

# Append compose environment variables to a container config.
_inject_env() {
    local vmid="$1" env_json="$2"
    echo "$env_json" | python3 -c "
import sys, json
env = json.load(sys.stdin)
for k, v in env.items():
    print(f'lxc.environment.runtime: {k}={v}')
" >> "/etc/pve/lxc/${vmid}.conf"
}

_detect_bridges() {
    IFACE_FILEPATH_LIST="/etc/network/interfaces"$'\n'$(find "/etc/network/interfaces.d/" -type f 2>/dev/null)
    BRIDGES=""
    local OLD_IFS=$IFS
    IFS=$'\n'
    for iface_filepath in ${IFACE_FILEPATH_LIST}; do
      local iface_indexes_tmpfile=$(mktemp -q -u '.iface-XXXX')
      (grep -Pn '^\s*iface' "${iface_filepath}" 2>/dev/null | cut -d':' -f1 && wc -l "${iface_filepath}" 2>/dev/null | cut -d' ' -f1) | awk 'FNR==1 {line=$0; next} {print line":"$0-1; line=$0}' >"${iface_indexes_tmpfile}" 2>/dev/null || true
      if [ -f "${iface_indexes_tmpfile}" ]; then
        while read -r pair; do
          local start=$(echo "${pair}" | cut -d':' -f1)
          local end=$(echo "${pair}" | cut -d':' -f2)
          if awk "NR >= ${start} && NR <= ${end}" "${iface_filepath}" 2>/dev/null | grep -qP '^\s*(bridge[-_](ports|stp|fd|vlan-aware|vids)|ovs_type\s+OVSBridge)\b'; then
            local iface_name=$(sed "${start}q;d" "${iface_filepath}" | awk '{print $2}')
            BRIDGES="${iface_name}"$'\n'"${BRIDGES}"
          fi
        done <"${iface_indexes_tmpfile}"
        rm -f "${iface_indexes_tmpfile}"
      fi
    done
    IFS=$OLD_IFS
    BRIDGES=$(echo "$BRIDGES" | grep -v '^\s*$' | sort | uniq)

    # Build bridge menu
    BRIDGE_MENU_OPTIONS=()
    if [[ -n "$BRIDGES" ]]; then
      while read -r line; do
        if [[ $line =~ ^(vmbr[0-9]+)\ +(.*) ]]; then
          bridge="${BASH_REMATCH[1]}"
          description="${BASH_REMATCH[2]}"
          # Append as separate elements: Tag Item
          BRIDGE_MENU_OPTIONS+=("$bridge" "${description:-Active}")
        elif [[ $line =~ ^(vmbr[0-9]+)$ ]]; then
           BRIDGE_MENU_OPTIONS+=("${BASH_REMATCH[1]}" "Active")
        fi
      done <<<"$BRIDGES"
    fi
}

# Ingest Project function
# Handles URL/File input, determining project name, and setting up directory
_ingest_project() {
    # echo "--- Project Setup ---"
    if ! tui_input "Enter Compose File Path or URL:" "docker-compose.yml" INPUT_SOURCE; then return; fi
    INPUT_SOURCE=${INPUT_SOURCE:-docker-compose.yml}
    
    # Detect extension to preserve (yml, yaml, json)
    # Default to .yml
    EXT="yml"
    if [[ "$INPUT_SOURCE" =~ \.yaml$ ]]; then EXT="yaml"; fi
    if [[ "$INPUT_SOURCE" =~ \.json$ ]]; then EXT="json"; fi

    local tmp_compose="$TMP_DIR/docker-compose.$EXT"
    
    # 1. Fetch File
    if [[ "$INPUT_SOURCE" =~ ^https?:// ]]; then
        # echo "Downloading from URL..."
        if ! curl -L -o "$tmp_compose" "$INPUT_SOURCE"; then
            tui_msg "Error: Failed to download file."
            exit 1
        fi
    else
        if [ ! -f "$INPUT_SOURCE" ]; then
             tui_msg "Error: File $INPUT_SOURCE not found."
             exit 1
        fi
        cp "$INPUT_SOURCE" "$tmp_compose"
    fi
    
    # 2. Parse Project Name
    # We use the python parser logic briefly here just to extract 'name'
    PROJECT_NAME=$(python3 -c '
import yaml, sys
try:
    with open("'$tmp_compose'", "r") as f:
        data = yaml.safe_load(f)
        print(data.get("name", ""))
except:
    print("")
')
    
    if [ -z "$PROJECT_NAME" ]; then
        if ! tui_input "Project Name (not found in compose):" "" PROJECT_NAME; then exit 1; fi
        if [ -z "$PROJECT_NAME" ]; then tui_msg "Error: Name required."; exit 1; fi
    fi
    
    # Sanitize name
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -dc 'a-zA-Z0-9-_')
    
    # 3. Setup Directory
    PROJECT_DIR="$PROJECT_BASE_DIR/$PROJECT_NAME"
    if [ -d "$PROJECT_DIR" ]; then
        if ! tui_yesno "Project '$PROJECT_NAME' already exists. Update/Reinstall?"; then exit 1; fi
        # For now, we just overwrite the compose file. Future: Handle full update flow.
    else
        mkdir -p "$PROJECT_DIR"
    fi
    
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.$EXT"
    cp "$tmp_compose" "$COMPOSE_FILE"
    
    # 3b. Interactive Edit
    if [ -t 0 ]; then
        if tui_yesno "Open compose file for review/edit?"; then
            nano "$COMPOSE_FILE"
        fi
    fi
    
    # 4. Init Metadata
    METADATA_FILE="$PROJECT_DIR/metadata.json"
    if [ ! -f "$METADATA_FILE" ]; then
        # Create initial metadata
        python3 -c '
import json, datetime
meta = {
    "name": "'"$PROJECT_NAME"'",
    "source": "'"$INPUT_SOURCE"'",
    "install_date": datetime.datetime.now().isoformat(),
    "services": [],
    "config": {}
}
with open("'$METADATA_FILE'", "w") as f:
    json.dump(meta, f, indent=2)
'
    fi
    
    # echo "Project '$PROJECT_NAME' staged at $PROJECT_DIR"
}

_save_project_config() {
    # Update config section of metadata
    python3 - "$METADATA_FILE" "$TARGET_NODE" "$TEMPLATE_STORAGE" "$ROOTFS_STORAGE" "$VOL_STORAGE" "$VOL_SIZE" "$NET_BRIDGE" "$IP_CONFIG" "$NET_CIDR" "$NET_GW" <<'EOF'
import json, sys
meta_path = sys.argv[1]
try:
    with open(meta_path, "r") as f:
        data = json.load(f)
except:
    data = {}

data["config"] = {
    "node": sys.argv[2],
    "template_storage": sys.argv[3],
    "rootfs_storage": sys.argv[4],
    "volume_storage": sys.argv[5],
    "volume_size": sys.argv[6],
    "bridge": sys.argv[7],
    "ip_config": sys.argv[8],
    "net_cidr": sys.argv[9],
    "net_gw": sys.argv[10]
}

with open(meta_path, "w") as f:
    json.dump(data, f, indent=2)
EOF
}

_load_project_config() {
    if [ -f "$METADATA_FILE" ]; then
        eval $(python3 - "$METADATA_FILE" <<'EOF'
import json, sys
try:
    with open(sys.argv[1], "r") as f:
        data = json.load(f)
    cfg = data.get("config", {})
    if cfg:
        print(f'TARGET_NODE="{cfg.get("node", "")}"')
        print(f'TEMPLATE_STORAGE="{cfg.get("template_storage", "")}"')
        print(f'ROOTFS_STORAGE="{cfg.get("rootfs_storage", "")}"')
        print(f'VOL_STORAGE="{cfg.get("volume_storage", "")}"')
        print(f'VOL_SIZE="{cfg.get("volume_size", "16G")}"')
        print(f'NET_BRIDGE="{cfg.get("bridge", "")}"')
        print(f'IP_CONFIG="{cfg.get("ip_config", "dhcp")}"')
        print(f'NET_CIDR="{cfg.get("net_cidr", "")}"')
        print(f'NET_GW="{cfg.get("net_gw", "")}"')
        print("CONFIG_LOADED=true")
    else:
        print("CONFIG_LOADED=false")
except:
    print("CONFIG_LOADED=false")
EOF
)
    else
        CONFIG_LOADED=false
    fi
}

_update_metadata() {
    # Updates the metadata file with the given JSON content for services
    # input: JSON string of services list
    local SERVICES_JSON="$1"
    
    python3 -c '
import json, sys
meta_path = "'$METADATA_FILE'"
services = json.loads(sys.argv[1])
try:
    with open(meta_path, "r") as f:
         data = json.load(f)
except:
    data = {}

data["services"] = services

with open(meta_path, "w") as f:
    json.dump(data, f, indent=2)
' "$SERVICES_JSON"
}



# --- Core Logic ---

install_project() {
    created_vmids=()
    # 1. Project Ingestion
    _ingest_project
    # COMPOSE_FILE and PROJECT_NAME are now set. METADATA_FILE is set.
    # (Updates of existing projects go through update_project, not here.)

    # 2. Inputs for Deployment
    # Logic: If CONFIG_LOADED is true, verify variables, else prompt.
    
    # Node Selection
    if [ -z "$TARGET_NODE" ]; then
        mapfile -t NODES < <(pvesh get /nodes --output-format json | python3 -c 'import sys, json; print("\n".join([n["node"] for n in json.load(sys.stdin)]))')
        if [ ${#NODES[@]} -eq 1 ]; then
            TARGET_NODE="${NODES[0]}"
            tui_msg "Auto-selected only node: $TARGET_NODE"
        else
            # Build menu options: Node Node
            OPTS=()
            for n in "${NODES[@]}"; do OPTS+=("$n" "$n"); done
            TARGET_NODE=$(tui_menu "Select Target Node" 15 60 4 "${OPTS[@]}")
            if [ -z "$TARGET_NODE" ]; then return; fi
        fi
    else
        echo "Using Configured Node: $TARGET_NODE"
    fi

    # Template Storage
    if [ -z "$TEMPLATE_STORAGE" ]; then
        mapfile -t STORAGES < <(pvesh get /nodes/$TARGET_NODE/storage --output-format json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for s in data:
    if "vztmpl" in s.get("content", ""):
        print(s["storage"])
')
        if [ ${#STORAGES[@]} -eq 1 ]; then
             TEMPLATE_STORAGE="${STORAGES[0]}"
             tui_msg "Auto-selected template storage: $TEMPLATE_STORAGE"
        else
             OPTS=()
             for s in "${STORAGES[@]}"; do OPTS+=("$s" "$s"); done
             TEMPLATE_STORAGE=$(tui_menu "Select Template Storage (vztmpl)" 15 60 4 "${OPTS[@]}")
             if [ -z "$TEMPLATE_STORAGE" ]; then return; fi
        fi
    else
        echo "Using Configured Template Storage: $TEMPLATE_STORAGE"
    fi

    # RootFS Storage Selection
    if [ -z "$ROOTFS_STORAGE" ]; then
        mapfile -t STORAGES < <(pvesh get /nodes/$TARGET_NODE/storage --output-format json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for s in data:
    if "rootdir" in s.get("content", ""):
        print(s["storage"])
')
        if [ ${#STORAGES[@]} -eq 1 ]; then
             ROOTFS_STORAGE="${STORAGES[0]}"
             tui_msg "Auto-selected container storage: $ROOTFS_STORAGE"
        else
             OPTS=()
             for s in "${STORAGES[@]}"; do OPTS+=("$s" "$s"); done
             ROOTFS_STORAGE=$(tui_menu "Select Container Storage (rootdir)" 15 60 4 "${OPTS[@]}")
             if [ -z "$ROOTFS_STORAGE" ]; then return; fi
        fi
    else
        echo "Using Configured Container Storage: $ROOTFS_STORAGE"
    fi

    # Volume Storage (Virtual Disks)
    if [ -z "$VOL_STORAGE" ]; then
        if ! tui_input "Target Volume Storage ID (Content 'images' or 'rootdir'):" "$ROOTFS_STORAGE" VOL_STORAGE; then return; fi
        VOL_STORAGE=${VOL_STORAGE:-$ROOTFS_STORAGE}
    fi

    # Volume Size
    if [ -z "$VOL_SIZE" ]; then
        if ! tui_input "Volume Size (numeric+unit, e.g. 16G):" "16G" VOL_SIZE; then return; fi
        VOL_SIZE=${VOL_SIZE:-16G}
    fi

    # Network Bridge
    if [ -z "$NET_BRIDGE" ]; then
        _detect_bridges
        if [ ${#BRIDGE_MENU_OPTIONS[@]} -eq 2 ]; then
            # Format is (Tag Item), so 2 elements = 1 option
            NET_BRIDGE="${BRIDGE_MENU_OPTIONS[0]}"
            tui_msg "Auto-selected only bridge: $NET_BRIDGE"
        elif [ ${#BRIDGE_MENU_OPTIONS[@]} -gt 0 ]; then
             NET_BRIDGE=$(tui_menu "Select Network Bridge" 15 60 4 "${BRIDGE_MENU_OPTIONS[@]}")
             if [ -z "$NET_BRIDGE" ]; then return; fi
        else
            if ! tui_input "No bridges detected. Enter bridge name:" "vmbr0" NET_BRIDGE; then return; fi
        fi
        NET_BRIDGE=${NET_BRIDGE:-vmbr0}
    else
        echo "Using Configured Bridge: $NET_BRIDGE"
    fi

    # Network Configuration (DHCP vs Static)
    if [ -z "$IP_CONFIG" ]; then
         IP_CONFIG=$(tui_menu "IP Configuration" 10 60 2 "dhcp" "Auto (DHCP)" "static" "Static IP")
         if [ -z "$IP_CONFIG" ]; then return; fi
        
        if [ "$IP_CONFIG" = "static" ]; then
            if ! tui_input "IPv4/CIDR (e.g. 192.168.1.10/24):" "" NET_CIDR; then return; fi
            if ! tui_input "Gateway (e.g. 192.168.1.1):" "" NET_GW; then return; fi
        fi
    fi
    
    if [ "$IP_CONFIG" = "static" ]; then
        NET_OPTS="ip=$NET_CIDR,gw=$NET_GW"
    else
        NET_OPTS="ip=dhcp"
    fi

    # Save Config
    _save_project_config

    # Starting VMID
    DEFAULT_VMID=$(get_next_vmid)
    if ! tui_input "Starting VMID:" "$DEFAULT_VMID" START_VMID; then return; fi
    START_VMID=${START_VMID:-$DEFAULT_VMID}

# Global Volume Tracking
declare -A GLOBAL_VOL_MAP

# 3. Parse Compose File
echo "Parsing $COMPOSE_FILE..."
mapfile -t SERVICES < <(parse_compose)

CURRENT_VMID=$START_VMID

# Metadata collection Array
METADATA_SERVICES_JSON="[]"

for SERVICE_LINE in "${SERVICES[@]}"; do
    IFS=$'\t' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON <<< "$SERVICE_LINE"
    
    echo ""
    echo "--- Deploying Service: $S_NAME ---"
    echo "Image: $S_IMAGE"
    echo "Target VMID: $CURRENT_VMID"
    
    # Metadata for this service
    SERVICE_VOLUMES_LOG="[]"

    # --- 1. Volume Processing Preparation ---
    declare -a PENDING_VOLUMES
    MP_INDEX=0
    # Process S_VOLS_JSON into an array for later iteration
    if [ -n "$S_VOLS_JSON" ] && [ "$S_VOLS_JSON" != "[]" ]; then
         while read -r VOL_ITEM; do
             [ -z "$VOL_ITEM" ] && continue
             PENDING_VOLUMES+=("$VOL_ITEM")
         done < <(echo "$S_VOLS_JSON" | python3 -c "import sys, json; print('\n'.join(['|'.join([v['type'], v['source'], v['target']]) for v in json.load(sys.stdin)]))")
    fi

    # --- 2. Pull Image (sets TEMPLATE_VOLID) ---
    _pull_image "$S_IMAGE" || exit 1

    # --- 4. Create Container (RootFS Only) ---
    echo "Creating container $CURRENT_VMID..."
    
    # Sanitize size (strip G/GB) for ZFS compatibility
    CLEAN_VOL_SIZE=$(echo "$VOL_SIZE" | tr -cd '0-9')
    
    pct create $CURRENT_VMID "$TEMPLATE_VOLID" \
        --hostname "$S_NAME" \
        --cores 1 \
        --memory 512 \
        --swap 512 \
        --net0 "name=eth0,bridge=$NET_BRIDGE,firewall=1,$NET_OPTS" \
        --rootfs "$ROOTFS_STORAGE:$CLEAN_VOL_SIZE" \
        --features nesting=1 \
        --unprivileged 1 \
        --start 0 || { echo "Error: Failed to create container $CURRENT_VMID"; exit 1; }
    
    VMID_FOR_TRACKING=$CURRENT_VMID

    # --- 5. Post-Creation Volume Attachment (pct set) ---
    echo "Processing volumes..."
    MP_INDEX=0
    for VOL_ITEM in "${PENDING_VOLUMES[@]}"; do
        [ -z "$VOL_ITEM" ] && continue
        IFS='|' read -r V_TYPE V_SOURCE V_TARGET <<< "$VOL_ITEM"
        
        MOUNT_STR=""
        IS_NEW_ALLOCATION="false"
        PROXMOX_VOLID=""

        # 1. Check Global Map (Current Session Shared)
        if [[ -n "${GLOBAL_VOL_MAP[$V_SOURCE]}" ]]; then
                PROXMOX_VOLID="${GLOBAL_VOL_MAP[$V_SOURCE]}"
                echo "Attaching shared volume '$V_SOURCE': $PROXMOX_VOLID"
                MOUNT_STR="$PROXMOX_VOLID,mp=$V_TARGET"
        
        # 2. Create New (pct set storage:size)
        else
                echo "Creating new volume for '$V_SOURCE'..."
                # Syntax: storage:size (size in GB, numeric only)
                MOUNT_STR="$VOL_STORAGE:$CLEAN_VOL_SIZE,mp=$V_TARGET"
                IS_NEW_ALLOCATION="true"
        fi
        
        # Execute pct set
        if [ -n "$MOUNT_STR" ]; then
            pct set $CURRENT_VMID "-mp$MP_INDEX" "$MOUNT_STR" || { echo "Error: Failed to attach volume $V_SOURCE to $CURRENT_VMID"; exit 1; }
             
            # If we just created a new allocated volume, we MUST find its ID
            if [ "$IS_NEW_ALLOCATION" == "true" ]; then
                # Scrape config
                NEW_VOL_CONFIG=$(pct config $CURRENT_VMID | grep "^mp$MP_INDEX:")
                # Format: mp0: local-zfs:vm-800-disk-1,mp=/data,...
                PROXMOX_VOLID=$(echo "$NEW_VOL_CONFIG" | sed -E 's/^mp[0-9]+: ([^,]+).*/\1/')
            fi
            
            # Log for metadata (JSON object)
            SAFE_SRC=$(echo "$V_SOURCE" | sed 's/"/\\"/g')
            SAFE_VOL=$(echo "$PROXMOX_VOLID" | sed 's/"/\\"/g')
            SAFE_MP=$(echo "$V_TARGET" | sed 's/"/\\"/g')
            
            VOL_ENTRY="{\"source\": \"$SAFE_SRC\", \"volid\": \"$SAFE_VOL\", \"mp\": \"$SAFE_MP\", \"type\": \"$V_TYPE\"}"
            SERVICE_VOLUMES_LOG=$(echo "$SERVICE_VOLUMES_LOG" | python3 -c "import sys, json; l=json.load(sys.stdin); l.append($VOL_ENTRY); print(json.dumps(l))")
            
            MP_INDEX=$((MP_INDEX + 1))
        fi
    done

    # --- 6. Inject Env Vars ---
    echo "Setting environment variables..."
    _inject_env "$CURRENT_VMID" "$S_ENV_JSON"
    echo "Environment variables injected."

    # --- 7. Start ---
    echo "Starting container..."
    pct start $CURRENT_VMID || echo "Warning: Container $CURRENT_VMID failed to start."
    echo "Service $S_NAME deployed to $CURRENT_VMID"
    
    # --- 8. Update Metadata Accumulator ---
    METADATA_SERVICES_JSON=$(echo "$METADATA_SERVICES_JSON" | python3 -c "
import sys, json
services = json.load(sys.stdin)
services.append({
    'name': '$S_NAME',
    'vmid': $CURRENT_VMID,
    'container_storage': '$ROOTFS_STORAGE',
    'volumes': json.loads('$SERVICE_VOLUMES_LOG')
})
print(json.dumps(services))
")

    CURRENT_VMID=$((CURRENT_VMID + 1))
    created_vmids+=("$VMID_FOR_TRACKING")
done

    # Finalize Metadata
    echo "Updating project metadata..."
    _update_metadata "$METADATA_SERVICES_JSON"

    echo "Deployment Complete! Project saved to $PROJECT_DIR"
}

manage_projects() {
    # List projects in base dir
    PROJECTS=($(ls -d "$PROJECT_BASE_DIR"/*/ 2>/dev/null | xargs -n 1 basename))
    
    if [ ${#PROJECTS[@]} -eq 0 ]; then
        tui_msg "No projects found."
        return
    fi
    
    # Build Menu
    local i=1
    OPTS=()
    for p in "${PROJECTS[@]}"; do
        OPTS+=("$p" "Project")
    done
    
    selected_project=$(tui_menu "Select Project" 15 60 6 "${OPTS[@]}")
    if [ -z "$selected_project" ]; then return; fi
    
    local p_name="$selected_project"
    local p_dir="$PROJECT_BASE_DIR/$p_name"
    local meta_path="$p_dir/metadata.json"
    
    # Get details via python for display in msgbox
    DETAILS=$(python3 -c '
import sys, json
try:
    with open("'$meta_path'", "r") as f:
        data = json.load(f)
        src = data.get("source", "N/A")
        inst = data.get("install_date", "N/A")
        print(f"Source: {src}\nInstalled: {inst}\n\nServices:")
        for s in data.get("services", []):
             print(f"- {s.get("name", "?")} (VMID: {s.get("vmid", "?")})")
except:
    print("Error reading metadata")
')

    # Sub-menu for Project
    ACTION=$(whiptail --title "Project: $p_name" --menu "$DETAILS" 20 70 4 \
        "1" "Update Project" \
        "2" "Delete Project" \
        "3" "Back" 3>&1 1>&2 2>&3)
        
    case $ACTION in
        1)
            update_project "$selected_project"
            ;;
        2)
            delete_project "$selected_project"
            ;;
    esac
}

ASSUME_YES="false"

# Confirmation / notices that also work non-interactively (CLI with --yes).
_confirm() {
    if [ "$ASSUME_YES" = "true" ]; then return 0; fi
    tui_yesno "$1"
}

_notify() {
    if [ "$ASSUME_YES" = "true" ] || [ ! -t 0 ]; then
        echo "$1"
    else
        tui_msg "$1"
    fi
}

# Read a container config (main section only) and print tab-separated records
# describing what must survive an update:
#   ROOTFS <storage> <size-in-GB>
#   HOSTNAME <name> / UNPRIV <0|1>
#   KEEP <key> <value>        settings re-applied with pct set
#   DATAMP <key> <mp-target>  storage-backed mount points (moved, never destroyed)
#   BINDMP <key> <value>      host-path bind mounts (re-added verbatim)
#   RAW <line>                description comments and non-image lxc.* lines
#   ENV <key>                 environment keys currently set
_describe_container() {
    python3 - "/etc/pve/lxc/$1.conf" <<'EOF'
import re, sys
keep_keys = {"cores", "cpulimit", "cpuunits", "memory", "swap", "onboot", "startup",
             "tags", "nameserver", "searchdomain", "timezone", "hookscript", "features"}
# lxc.* keys that come from the OCI image and must be taken from the new image
image_lxc = ("lxc.environment.runtime", "lxc.init.", "lxc.signal.")
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("["):
            break  # snapshots / pending section
        if line.startswith("#"):
            print(f"RAW\t{line}")
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key, value = key.strip(), value.strip()
        if key.startswith("lxc."):
            if key == "lxc.environment.runtime":
                print(f"ENV\t{value.split('=', 1)[0]}")
            elif not key.startswith(image_lxc):
                print(f"RAW\t{line}")
            continue
        if key == "rootfs":
            volid = value.split(",")[0]
            m = re.search(r"size=(\d+)([MGT]?)", value)
            size = 8
            if m:
                n, unit = int(m.group(1)), m.group(2)
                size = max(1, n // 1024) if unit == "M" else n * 1024 if unit == "T" else n
            print(f"ROOTFS\t{volid.split(':')[0]}\t{size}")
        elif key == "hostname":
            print(f"HOSTNAME\t{value}")
        elif key == "unprivileged":
            print(f"UNPRIV\t{value}")
        elif re.fullmatch(r"net\d+", key) or key in keep_keys:
            print(f"KEEP\t{key}\t{value}")
        elif re.fullmatch(r"mp\d+", key):
            source = value.split(",")[0]
            target = re.search(r"(?:^|,)mp=([^,]+)", value)
            if source.startswith("/"):
                print(f"BINDMP\t{key}\t{value}")
            else:
                print(f"DATAMP\t{key}\t{target.group(1) if target else ''}")
EOF
}

# Move every DATAMP volume from one container to another, keeping the mpN key.
_move_data_volumes() {
    local from="$1" to="$2"; shift 2
    local key
    for key in "$@"; do
        echo "Moving $key: $from -> $to"
        pct move-volume "$from" "$key" --target-vmid "$to" --target-volume "$key" || return 1
    done
}

# Replace a service container with a fresh one built from the current image,
# keeping its VMID, network identity (MAC/IP), resources, mounts and data.
#
# PVE cannot reassign a rootfs between containers, and destroying a container
# deletes every volume it owns (including detached "unused" ones), so data
# volumes are parked on a staging container while the service is rebuilt.
update_service() {
    local name="$1" vmid="$2" image="$3" env_json="$4" vols_json="$5"
    local conf="/etc/pve/lxc/${vmid}.conf"

    echo ""
    echo "--- Updating Service: $name (VMID $vmid) ---"

    # 1. Pre-flight checks (nothing is changed yet)
    if [ ! -f "$conf" ]; then
        echo "Error: Container $vmid does not exist. Skipping."
        return 1
    fi
    if grep -q '^protection: 1' "$conf"; then
        echo "Error: Container $vmid has protection enabled. Disable it first (pct set $vmid --protection 0)."
        return 1
    fi
    if grep -q '^\[pve:pending\]' "$conf"; then
        echo "Error: Container $vmid has pending config changes that would be lost. Apply them first (restart it), then update."
        return 1
    fi
    local snaps
    snaps=$(pct listsnapshot "$vmid" 2>/dev/null | grep -v -- '-> current' | sed -E 's/^[^[:alnum:]]*([^ ]+).*/\1/' | tr '\n' ' ')
    if [ -n "${snaps// /}" ]; then
        echo "Error: Container $vmid has snapshots ($snaps). PVE cannot move volumes of a container with snapshots."
        echo "       Remove them first: pct delsnapshot $vmid <name>"
        return 1
    fi

    local rootfs_storage="" rootfs_size="" hostname="$name" unpriv="1"
    local -a keep_keys=() keep_vals=() data_keys=() data_targets=() bind_keys=() bind_vals=() raw_lines=() old_env=()
    local type a b
    while IFS=$'\t' read -r type a b; do
        case "$type" in
            ROOTFS) rootfs_storage="$a"; rootfs_size="$b" ;;
            HOSTNAME) hostname="$a" ;;
            UNPRIV) unpriv="$a" ;;
            KEEP) keep_keys+=("$a"); keep_vals+=("$b") ;;
            DATAMP) data_keys+=("$a"); data_targets+=("$b") ;;
            BINDMP) bind_keys+=("$a"); bind_vals+=("$b") ;;
            RAW) raw_lines+=("$a") ;;
            ENV) old_env+=("$a") ;;
        esac
    done < <(_describe_container "$vmid")
    rootfs_storage="${rootfs_storage:-$ROOTFS_STORAGE}"
    rootfs_size="${rootfs_size:-8}"

    local backup="$PROJECT_DIR/${vmid}-$(date +%Y%m%d-%H%M%S).conf.bak"
    cp "$conf" "$backup"
    echo "Saved current config to $backup"

    # 2. Pull the new image and prove it can be turned into a container
    local prev_template
    prev_template=$(_list_templates "$image" | LC_ALL=C sort | tail -n 1)
    _pull_image "$image" || return 1

    local stage
    stage=$(get_next_vmid)
    echo "Creating staging container $stage from the new image..."
    if ! pct create "$stage" "$TEMPLATE_VOLID" --hostname "pmxc-stage-$vmid" --rootfs "$rootfs_storage:$rootfs_size" \
            --memory 64 --unprivileged "$unpriv" --start 0 >/dev/null; then
        echo "Error: The new image could not be turned into a container. Service $name was not touched."
        pct destroy "$stage" --purge >/dev/null 2>&1
        return 1
    fi

    # 3. Stop the service and park its data volumes on the staging container
    local was_running="false"
    if pct status "$vmid" | grep -q running; then was_running="true"; fi
    if [ "$was_running" = "true" ]; then
        echo "Stopping container $vmid..."
        pct shutdown "$vmid" --timeout 60 >/dev/null 2>&1 || pct stop "$vmid"
    fi

    PARKED_VOLUMES_ON="$stage"
    if ! _move_data_volumes "$vmid" "$stage" "${data_keys[@]}"; then
        echo "Error: Failed to park data volumes. Moving back what was moved and restarting $vmid..."
        local k
        for k in "${data_keys[@]}"; do
            grep -q "^$k:" "/etc/pve/lxc/${stage}.conf" && pct move-volume "$stage" "$k" --target-vmid "$vmid" --target-volume "$k"
        done
        PARKED_VOLUMES_ON=""
        pct destroy "$stage" --purge >/dev/null 2>&1
        [ "$was_running" = "true" ] && pct start "$vmid"
        return 1
    fi

    # 4. Rebuild the service container under the same VMID.
    # No --purge: keep the VMID in backup jobs, replication and HA.
    local fw_conf="/etc/pve/firewall/${vmid}.fw" fw_backup=""
    if [ -f "$fw_conf" ]; then
        fw_backup="$PROJECT_DIR/${vmid}-$(date +%Y%m%d-%H%M%S).fw.bak"
        cp "$fw_conf" "$fw_backup"
    fi

    echo "Destroying old container $vmid (data volumes are safe on $stage)..."
    if ! pct destroy "$vmid"; then
        echo "Error: Could not destroy $vmid. Moving data back..."
        _move_data_volumes "$stage" "$vmid" "${data_keys[@]}" && PARKED_VOLUMES_ON="" && pct destroy "$stage" --purge >/dev/null 2>&1
        [ "$was_running" = "true" ] && pct start "$vmid"
        return 1
    fi

    echo "Recreating container $vmid from the new image..."
    if ! pct create "$vmid" "$TEMPLATE_VOLID" --hostname "$hostname" --rootfs "$rootfs_storage:$rootfs_size" \
            --unprivileged "$unpriv" --start 0 >/dev/null; then
        echo "Error: Failed to recreate container $vmid. Old config: $backup"
        return 1   # PARKED_VOLUMES_ON stays set, so the exit trap tells the user where the data is
    fi

    [ -n "$fw_backup" ] && cp "$fw_backup" "$fw_conf"

    local i
    for i in "${!keep_keys[@]}"; do
        pct set "$vmid" "--${keep_keys[$i]}" "${keep_vals[$i]}" || echo "Warning: could not restore ${keep_keys[$i]}"
    done
    for i in "${!bind_keys[@]}"; do
        pct set "$vmid" "--${bind_keys[$i]}" "${bind_vals[$i]}" || echo "Warning: could not restore bind mount ${bind_keys[$i]}"
    done

    # 5. Bring the data back
    if ! _move_data_volumes "$stage" "$vmid" "${data_keys[@]}"; then
        echo "Error: Failed to move data volumes back to $vmid. Old config: $backup"
        return 1
    fi
    PARKED_VOLUMES_ON=""
    pct destroy "$stage" --purge >/dev/null 2>&1 || echo "Warning: could not remove staging container $stage"

    # Compose volumes that don't exist yet get a new disk
    local v_type v_source v_target used n=0
    while IFS=$'\t' read -r v_type v_source v_target; do
        [ -z "$v_target" ] && continue
        used="false"
        for i in "${data_targets[@]}"; do [ "$i" = "$v_target" ] && used="true"; done
        [ "$used" = "true" ] && continue
        while grep -q "^mp$n:" "$conf"; do n=$((n + 1)); done
        echo "Creating new volume for '$v_source' at $v_target..."
        pct set "$vmid" "-mp$n" "$VOL_STORAGE:$(echo "$VOL_SIZE" | tr -cd '0-9'),mp=$v_target" || echo "Warning: could not create volume for $v_target"
    done < <(echo "$vols_json" | python3 -c "import sys, json; [print(f\"{v['type']}\t{v['source']}\t{v['target']}\") for v in json.load(sys.stdin)]")

    # 6. Environment: the new image's own variables plus the compose file's
    _inject_env "$vmid" "$env_json"
    if [ ${#raw_lines[@]} -gt 0 ]; then
        local tmp_conf="$TMP_DIR/$vmid.conf"
        { printf '%s\n' "${raw_lines[@]}" | grep '^#'; grep -v '^#' "$conf"; printf '%s\n' "${raw_lines[@]}" | grep -v '^#'; } > "$tmp_conf"
        cat "$tmp_conf" > "$conf"
    fi

    local dropped="" k
    for k in "${old_env[@]}"; do
        grep -q "^lxc.environment.runtime: $k=" "$conf" || dropped="$dropped $k"
    done
    [ -n "$dropped" ] && echo "Note: these variables were set before but come from neither the new image nor the compose file, so they were not carried over:$dropped"

    if [ "$was_running" = "true" ]; then
        echo "Starting container $vmid..."
        pct start "$vmid" || echo "Warning: Container $vmid failed to start."
    fi

    _prune_templates "$image" "$TEMPLATE_VOLID" "$prev_template"
    echo "Service $name updated."
}

# Rewrite the services section of metadata from the live container configs.
_refresh_metadata() {
    python3 - "$METADATA_FILE" "$COMPOSE_FILE" <<'EOF'
import json, re, sys, yaml
meta_path, compose_path = sys.argv[1], sys.argv[2]
with open(meta_path) as f:
    meta = json.load(f)
with open(compose_path) as f:
    compose = yaml.safe_load(f) or {}
sources = {}
for name, svc in (compose.get("services") or {}).items():
    for v in svc.get("volumes", []) or []:
        if isinstance(v, str):
            parts = v.split(":")
            src, tgt = parts[0], parts[1] if len(parts) > 1 else parts[0]
        else:
            src, tgt = v.get("source"), v.get("target")
        typ = "bind" if str(src).startswith((".", "/", "~")) else "global"
        sources[(name, tgt)] = (src, typ)
for s in meta.get("services", []):
    vols = []
    try:
        with open(f"/etc/pve/lxc/{s['vmid']}.conf") as f:
            for line in f:
                if line.startswith("["):
                    break
                m = re.match(r"^(mp\d+):\s*([^,]+),(?:.*,)?mp=([^,\n]+)", line)
                if m and not m.group(2).startswith("/"):
                    src, typ = sources.get((s["name"], m.group(3)), (m.group(3), "global"))
                    vols.append({"source": src, "volid": m.group(2), "mp": m.group(3), "type": typ})
    except FileNotFoundError:
        pass
    s["volumes"] = vols
with open(meta_path, "w") as f:
    json.dump(meta, f, indent=2)
EOF
}

update_project() {
    local p_name="$1"
    PROJECT_DIR="$PROJECT_BASE_DIR/$p_name"
    METADATA_FILE="$PROJECT_DIR/metadata.json"

    echo "Updating project '$p_name'..."

    # 1. Load Config & Verify
    _load_project_config
    if [ "$CONFIG_LOADED" != "true" ]; then
        _notify "Error: Project configuration not found in metadata. Cannot auto-update."
        return 1
    fi
    COMPOSE_FILE=$(ls "$PROJECT_DIR"/docker-compose.* 2>/dev/null | head -n 1)
    if [ -z "$COMPOSE_FILE" ]; then
        _notify "Error: No compose file found in $PROJECT_DIR."
        return 1
    fi

    # 2. Optionally refresh the compose file from its original URL
    local source
    source=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("source", ""))' "$METADATA_FILE")
    if [[ "$source" =~ ^https?:// ]] && [ "$ASSUME_YES" != "true" ]; then
        if tui_yesno "Re-download the compose file from its source?\n\n$source\n\nNo = keep the local copy (including your edits)."; then
            if curl -fsSL -o "$TMP_DIR/compose.new" "$source"; then
                cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
                cp "$TMP_DIR/compose.new" "$COMPOSE_FILE"
            else
                _notify "Warning: Download failed, using the local compose file."
            fi
        fi
    fi

    # 3. Match compose services to deployed containers
    local -A vmid_of=()
    local s_name s_vmid
    while IFS=$'\t' read -r s_name s_vmid; do
        vmid_of["$s_name"]="$s_vmid"
    done < <(python3 -c 'import json, sys
for s in json.load(open(sys.argv[1])).get("services", []):
    print(str(s.get("name")) + "\t" + str(s.get("vmid")))' "$METADATA_FILE")

    mapfile -t SERVICES < <(parse_compose)
    if [ ${#SERVICES[@]} -eq 0 ]; then
        _notify "Error: No services found in $COMPOSE_FILE."
        return 1
    fi

    local summary="" line S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON
    for line in "${SERVICES[@]}"; do
        IFS=$'\t' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON <<< "$line"
        summary="$summary\n- $S_NAME ($S_IMAGE) -> VMID ${vmid_of[$S_NAME]:-not deployed}"
    done
    if ! _confirm "Update '$p_name'?\n$summary\n\nEach container is rebuilt from a freshly pulled image under the same VMID. Data volumes are moved aside and back, never deleted."; then
        return 0
    fi

    # 4. Update each service
    local failed=0
    for line in "${SERVICES[@]}"; do
        IFS=$'\t' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON <<< "$line"
        if [ -z "${vmid_of[$S_NAME]}" ]; then
            echo "Skipping '$S_NAME': not deployed yet (new service in the compose file)."
            continue
        fi
        if ! update_service "$S_NAME" "${vmid_of[$S_NAME]}" "$S_IMAGE" "$S_ENV_JSON" "$S_VOLS_JSON"; then
            failed=$((failed + 1))
            # A failure with volumes still parked must stop everything
            [ -n "$PARKED_VOLUMES_ON" ] && exit 1
        fi
    done

    _refresh_metadata
    if [ $failed -gt 0 ]; then
        _notify "Update finished with $failed failed service(s). See the output above."
        return 1
    fi
    _notify "Update complete."
}

delete_project() {
    local p_name="$1"
    local p_dir="$PROJECT_BASE_DIR/$p_name"
    METADATA_FILE="$p_dir/metadata.json"

    if ! tui_yesno "WARNING: This will remove project '$p_name'. Continue?"; then return; fi

    # Check about volumes
    local KEEP_DATA="true"
    if tui_yesno "Do you want to DELETE the containers and their persistent volumes (DATA LOSS)?\n\nSelect YES to DELETE everything.\nSelect NO to KEEP the data: containers are stopped and kept (tagged pmxc-detached) instead of destroyed."; then
        KEEP_DATA="false"
    fi

    echo "Processing deletion for $p_name..."

    # Load VMIDs
    mapfile -t VMID_LIST < <(python3 -c '
import json
try:
    with open("'$METADATA_FILE'", "r") as f:
        data = json.load(f)
    for s in data.get("services", []):
        print(s.get("vmid"))
except:
    pass
')

    for vmid in "${VMID_LIST[@]}"; do
        if [ -n "$vmid" ]; then
            echo "Stopping container $vmid..."
            pct stop $vmid || true

            if [ "$KEEP_DATA" = "true" ]; then
                # Destroying a container deletes every volume it owns, even
                # detached ones, so the only way to keep the data is to keep
                # the (stopped) container.
                echo "Keeping container $vmid (stopped, onboot disabled) to preserve its data..."
                local tags
                tags=$(pct config $vmid | awk '/^tags:/ {print $2}')
                pct set $vmid --onboot 0 --tags "${tags:+$tags;}pmxc-detached" || true
            else
                echo "Destroying container $vmid..."
                pct destroy $vmid --purge || echo "Warning: Failed to destroy $vmid"
            fi
        fi
    done

    # Remove Project Directory
    echo "Removing project files..."
    rm -rf "$p_dir"

    tui_msg "Project '$p_name' deleted."
}

main_menu() {
    while true; do
        clear 2>/dev/null || echo ""
        echo "========================================"
        echo "   Proxmox Compose Manager (v$PMXC_VERSION)       "
        CHOICE=$(whiptail --title "Proxmox OCI Composer" --menu "Main Menu" 15 60 4 \
            "1" "Install New Project" \
            "2" "Manage Projects" \
            "3" "Exit" 3>&1 1>&2 2>&3)

        EXIT_STATUS=$?
        if [ $EXIT_STATUS -ne 0 ]; then exit 0; fi

        case $CHOICE in
            1)
                install_project
                tui_msg "Installation process completed."
                ;;
            2)
                manage_projects
                ;;
            3)
                exit 0
                ;;
        esac
    done
}

usage() {
    echo "Usage: $0                       Interactive menu"
    echo "       $0 list                  List projects"
    echo "       $0 update <project> [-y] Update a project (-y: no prompts, keep local compose file)"
}

# --- Entry Point ---
case "${1:-}" in
    "")
        main_menu
        ;;
    list)
        ls -1 "$PROJECT_BASE_DIR" 2>/dev/null
        ;;
    update)
        if [ -z "${2:-}" ] || [ ! -d "$PROJECT_BASE_DIR/$2" ]; then
            echo "Error: Unknown project '${2:-}'."
            usage
            exit 1
        fi
        [ "${3:-}" = "-y" ] || [ "${3:-}" = "--yes" ] && ASSUME_YES="true"
        update_project "$2"
        exit $?
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
