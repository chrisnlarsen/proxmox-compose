#!/bin/bash

# Proxmox OCI Composer
# Reads a docker-compose.yml file and deploys services as OCI-based LXC containers on Proxmox VE 9.1+

set -e


# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

PROJECT_BASE_DIR="/var/lib/proxmox-compose"
# Temp dir for initial download
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

COMPOSE_FILE=""
PROJECT_NAME=""
PROJECT_DIR=""
METADATA_FILE=""

# Ensure base dir exists
mkdir -p "$PROJECT_BASE_DIR"

echo "Proxmox OCI Composer"
echo "===================="

# --- Embedded Python Parser ---
# Parses docker-compose.yml and outputs a JSON-like structure
# Output format per line: SERVICE_NAME|IMAGE|ENV_VARS_JSON
parse_compose() {
    python3 -c '
import yaml
import sys
import json

try:
    with open("docker-compose.yml", "r") as f:
        data = yaml.safe_load(f)

    if not data or "services" not in data:
        print("Error: No services found in docker-compose.yml", file=sys.stderr)
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

        print(f"{name}|{image}|{json.dumps(env)}|{json.dumps(volumes)}")

except Exception as e:
    print(f"Error parsing yaml: {e}", file=sys.stderr)
    sys.exit(1)
'
}

# --- Utils ---

# Function to get next available VMID
get_next_vmid() {
    local next_id=$(pvesh get /cluster/nextid)
    echo "$next_id"
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
      while IFS= read -r bridge; do
        if [[ -n "$bridge" ]]; then
          local description=$(grep -A 10 "iface $bridge" /etc/network/interfaces 2>/dev/null | grep '^#' | head -n1 | sed 's/^#\s*//')
          BRIDGE_MENU_OPTIONS+=("$bridge" "${description:- }")
        fi
      done <<<"$BRIDGES"
    fi
}

# Ingest Project function
# Handles URL/File input, determining project name, and setting up directory
_ingest_project() {
    echo "--- Project Setup ---"
    read -p "Enter Compose File Path or URL [docker-compose.yml]: " INPUT_SOURCE
    INPUT_SOURCE=${INPUT_SOURCE:-docker-compose.yml}
    
    local tmp_compose="$TMP_DIR/docker-compose.yml"
    
    # 1. Fetch File
    if [[ "$INPUT_SOURCE" =~ ^https?:// ]]; then
        echo "Downloading from URL..."
        if ! curl -L -o "$tmp_compose" "$INPUT_SOURCE"; then
            echo "Error: Failed to download file."
            exit 1
        fi
    else
        if [ ! -f "$INPUT_SOURCE" ]; then
             echo "Error: File $INPUT_SOURCE not found."
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
        echo "Project name not found in compose file (missing 'name:' field)."
        read -p "Enter Project Name: " PROJECT_NAME
        if [ -z "$PROJECT_NAME" ]; then echo "Error: Name required."; exit 1; fi
    fi
    
    # Sanitize name
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -dc 'a-zA-Z0-9-_')
    
    # 3. Setup Directory
    PROJECT_DIR="$PROJECT_BASE_DIR/$PROJECT_NAME"
    if [ -d "$PROJECT_DIR" ]; then
        echo "Project '$PROJECT_NAME' already exists at $PROJECT_DIR."
        read -p "Update/Reinstall? (y/n) " UPDATE_OPT
        if [ "$UPDATE_OPT" != "y" ]; then exit 1; fi
        # For now, we just overwrite the compose file. Future: Handle full update flow.
    else
        mkdir -p "$PROJECT_DIR"
    fi
    
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
    cp "$tmp_compose" "$COMPOSE_FILE"
    
    # 4. Init Metadata
    METADATA_FILE="$PROJECT_DIR/metadata.json"
    if [ ! -f "$METADATA_FILE" ]; then
        # Create initial metadata
        # We will use python to write json to ensure validity
        python3 -c '
import json, datetime
meta = {
    "name": "'"$PROJECT_NAME"'",
    "source": "'"$INPUT_SOURCE"'",
    "install_date": datetime.datetime.now().isoformat(),
    "services": [] 
}
with open("'$METADATA_FILE'", "w") as f:
    json.dump(meta, f, indent=2)
'
    fi
    
    echo "Project '$PROJECT_NAME' staged at $PROJECT_DIR"
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
    # 1. Project Ingestion
    _ingest_project
    # COMPOSE_FILE and PROJECT_NAME are now set.

    # 2. Inputs for Deployment (Node, Storage, Network)
# Node Selection
echo "Available Nodes:"
nodes=$(pvesh get /nodes --output-format json | python3 -c 'import sys, json; print("\n".join([n["node"] for n in json.load(sys.stdin)]))')
echo "$nodes"
read -p "Target Node: " TARGET_NODE

# Template Storage Selection
echo "Available Storages for Templates (vztmpl):"
pvesh get /nodes/$TARGET_NODE/storage --output-format json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for s in data:
    if "vztmpl" in s.get("content", ""):
        print(s["storage"])
'
read -p "Target Template Storage ID: " TEMPLATE_STORAGE

# RootFS Storage Selection
echo "Available Storages for Containers (rootdir):"
pvesh get /nodes/$TARGET_NODE/storage --output-format json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for s in data:
    if "rootdir" in s.get("content", ""):
        print(s["storage"])
'
read -p "Target Container Storage ID: " ROOTFS_STORAGE

# Volume Storage (Virtual Disks)
read -p "Target Volume Storage ID (Content 'images' or 'rootdir') [$ROOTFS_STORAGE]: " VOL_STORAGE
VOL_STORAGE=${VOL_STORAGE:-$ROOTFS_STORAGE}

# Volume Size
echo "Default Volume Size (e.g. 8G, 16G)."
echo "Note: If using thin provisioning (LVM-Thin/ZFS), it is safe to oversize."
read -p "Volume Size [16G]: " VOL_SIZE
VOL_SIZE=${VOL_SIZE:-16G}

# Network Bridge
echo "Detecting Bridges..."
_detect_bridges

echo "Available Bridges:"
if [ ${#BRIDGE_MENU_OPTIONS[@]} -eq 0 ]; then
    echo "No bridges detected via advanced method. Falling back to brctl/ip..."
    if command -v brctl >/dev/null; then
        brctl show | awk 'NR>1 {print $1}'
    else
         ip link show type bridge | awk -F': ' '{print $2}'
    fi
    read -p "Network Bridge (e.g., vmbr0): " NET_BRIDGE
else
    # Simple menu selection
    i=0
    for ((j=0; j<${#BRIDGE_MENU_OPTIONS[@]}; j+=2)); do
        echo "$((i+1)). ${BRIDGE_MENU_OPTIONS[j]} - ${BRIDGE_MENU_OPTIONS[j+1]}"
        ((i+=1))
    done
    read -p "Select Bridge [1]: " BRIDGE_SEL
    BRIDGE_SEL=${BRIDGE_SEL:-1}
    INDEX=$(( (BRIDGE_SEL - 1) * 2 ))
    NET_BRIDGE="${BRIDGE_MENU_OPTIONS[INDEX]}"
    if [ -z "$NET_BRIDGE" ]; then
        echo "Invalid selection, defaulting to vmbr0"
        NET_BRIDGE="vmbr0"
    else
        echo "Selected: $NET_BRIDGE"
    fi
fi

# Network Configuration (DHCP vs Static)
read -p "IP Configuration (dhcp/static) [dhcp]: " IP_CONFIG
IP_CONFIG=${IP_CONFIG:-dhcp}

if [ "$IP_CONFIG" = "static" ]; then
    read -p "IPv4/CIDR (e.g. 192.168.1.10/24): " NET_CIDR
    read -p "Gateway (e.g. 192.168.1.1): " NET_GW
    NET_OPTS="ip=$NET_CIDR,gw=$NET_GW"
else
    NET_OPTS="ip=dhcp"
fi

# Starting VMID
DEFAULT_VMID=$(get_next_vmid)
read -p "Starting VMID [$DEFAULT_VMID]: " START_VMID
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
    IFS='|' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON <<< "$SERVICE_LINE"
    
    echo ""
    echo "--- Deploying Service: $S_NAME ---"
    echo "Image: $S_IMAGE"
    echo "Target VMID: $CURRENT_VMID"
    
    # Metadata for this service
    SERVICE_VOLUMES_LOG="[]"

    # --- Volume Processing ---
    MOUNT_POINTS_ARGS=""
    MP_INDEX=0
    
    if [ -n "$S_VOLS_JSON" ] && [ "$S_VOLS_JSON" != "[]" ]; then
        echo "Processing volumes..."
        mapfile -t VOL_LIST < <(echo "$S_VOLS_JSON" | python3 -c '
import sys, json
vols = json.load(sys.stdin)
for v in vols:
    t = v["type"]
    s = v["source"]
    tgt = v["target"]
    print(f"{t}|{s}|{tgt}")
')
        for VOL_ITEM in "${VOL_LIST[@]}"; do
            IFS='|' read -r V_TYPE V_SOURCE V_TARGET <<< "$VOL_ITEM"
            PROXMOX_VOLID=""
            
            if [ "$V_TYPE" == "global" ]; then
                if [[ -n "${GLOBAL_VOL_MAP[$V_SOURCE]}" ]]; then
                    PROXMOX_VOLID="${GLOBAL_VOL_MAP[$V_SOURCE]}"
                    echo "Using existing global volume '$V_SOURCE': $PROXMOX_VOLID"
                else
                    echo "Allocating global volume '$V_SOURCE' on $VOL_STORAGE..."
                    ALLOC_NAME="vm-$CURRENT_VMID-disk-$MP_INDEX"
                    ALLOC_OUT=$(pvesm alloc $VOL_STORAGE $CURRENT_VMID $ALLOC_NAME $VOL_SIZE 2>&1)
                    PROXMOX_VOLID=$(echo "$ALLOC_OUT" | grep -o "$VOL_STORAGE:.*" | awk '{print $1}' | tr -d "'")
                    
                    if [ -z "$PROXMOX_VOLID" ]; then
                         echo "Error allocating volume $V_SOURCE. $ALLOC_OUT"
                         exit 1
                    fi
                    GLOBAL_VOL_MAP[$V_SOURCE]="$PROXMOX_VOLID"
                fi
            else
                echo "Allocating volume for '$V_SOURCE'..."
                ALLOC_NAME="vm-$CURRENT_VMID-disk-$MP_INDEX"
                ALLOC_OUT=$(pvesm alloc $VOL_STORAGE $CURRENT_VMID $ALLOC_NAME $VOL_SIZE 2>&1)
                PROXMOX_VOLID=$(echo "$ALLOC_OUT" | grep -o "$VOL_STORAGE:.*" | awk '{print $1}' | tr -d "'")
            fi
            
            if [ -n "$PROXMOX_VOLID" ]; then
                MOUNT_POINTS_ARGS="$MOUNT_POINTS_ARGS --mp$MP_INDEX $PROXMOX_VOLID,mp=$V_TARGET "
                
                # Log volume metadata
                SERVICE_VOLUMES_LOG=$(echo "$SERVICE_VOLUMES_LOG" | python3 -c "
import sys, json
log = json.load(sys.stdin)
log.append({'source': '$V_SOURCE', 'volid': '$PROXMOX_VOLID', 'mp': '$V_TARGET', 'type': '$V_TYPE'})
print(json.dumps(log))
")
                ((MP_INDEX+=1))
            fi
        done
    fi

    # 4. Pull Image
    echo "Pulling image '$S_IMAGE' to $TEMPLATE_STORAGE on $TARGET_NODE..."
    PULL_OUTPUT=$(pvesh create /nodes/$TARGET_NODE/storage/$TEMPLATE_STORAGE/oci-registry-pull --reference "$S_IMAGE" 2>&1 || true)
    UPID=$(echo "$PULL_OUTPUT" | grep -o "UPID:.*" | tail -n 1)
    
    if [ -z "$UPID" ]; then
        if echo "$PULL_OUTPUT" | grep -q "refusing to override"; then
             echo "Image '$S_IMAGE' already exists. Skipping pull."
        else
            echo "Error: Could not retrieve UPID from pull command."
            echo "$PULL_OUTPUT"
            exit 1
        fi
    else
        echo "Pull task started: $UPID"
        while true; do
            TASK_INFO=$(pvesh get /nodes/$TARGET_NODE/tasks/$UPID/status --output-format json 2>/dev/null)
            STATUS=$(echo "$TASK_INFO" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", "unknown"))' 2>/dev/null || echo "unknown")
            if [ "$STATUS" = "stopped" ]; then break; fi
            sleep 2
        done
        EXIT_STATUS=$(pvesh get /nodes/$TARGET_NODE/tasks/$UPID/status --output-format json | python3 -c 'import sys, json; print(json.load(sys.stdin).get("exitstatus", "unknown"))')
        if [ "$EXIT_STATUS" != "OK" ]; then
            echo "Error: Image pull failed. Exit status: $EXIT_STATUS"
            read -p "Continue anyway? (y/n) " CONT
            if [ "$CONT" != "y" ]; then exit 1; fi
        else
            echo "Image pulled successfully."
        fi
    fi

    # 5. Determine Template Path (Simplified reuse)
    # We repeat the check logic.
    echo "Locating template..."
    TEMPLATE_VOLID=$(pvesh get /nodes/$TARGET_NODE/storage/$TEMPLATE_STORAGE/content --content vztmpl --output-format json | python3 -c "
import sys, json
data = json.load(sys.stdin)
target_image = \"$S_IMAGE\"
found = None
for item in data:
    volid = item.get('volid')
    if target_image.split('/')[-1].split(':')[0] in volid:
         found = volid
         break
print(found if found else '')
")
    if [ -z "$TEMPLATE_VOLID" ]; then
        read -p "Enter full template path (e.g., $TEMPLATE_STORAGE:vztmpl/image.tar.zst): " TEMPLATE_VOLID
    else
        echo "Found template: $TEMPLATE_VOLID"
    fi

    # 6. Create Container
    echo "Creating container $CURRENT_VMID..."
    pct create $CURRENT_VMID $TEMPLATE_VOLID \
        --hostname "${S_NAME}-${HOSTNAME}" \
        --net0 name=eth0,bridge=$NET_BRIDGE,$NET_OPTS \
        --features nesting=1 \
        --unprivileged 1 \
        --storage $ROOTFS_STORAGE

    # Attach Volumes
    if [ -n "$MOUNT_POINTS_ARGS" ]; then
        echo "Attaching volumes..."
        pct set $CURRENT_VMID $MOUNT_POINTS_ARGS
    fi

    # 7. Inject Env Vars
    CONF_FILE="/etc/pve/lxc/${CURRENT_VMID}.conf"
    echo "Setting environment variables..."
    echo "$S_ENV_JSON" | python3 -c "
import sys, json
env = json.load(sys.stdin)
for k, v in env.items():
    print(f'lxc.environment: {k}={v}')
" >> "$CONF_FILE"
    echo "Environment variables injected."

    # 8. Start
    echo "Starting container..."
    pct start $CURRENT_VMID || echo "Warning: Container $CURRENT_VMID failed to start."
    echo "Service $S_NAME deployed to $CURRENT_VMID"
    
    # 9. Update Metadata Accumulator
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
done

    # Finalize Metadata
    echo "Updating project metadata..."
    _update_metadata "$METADATA_SERVICES_JSON"

    echo "Deployment Complete! Project saved to $PROJECT_DIR"
}

manage_projects() {
    echo "--- Installed Projects ---"
    if [ ! -d "$PROJECT_BASE_DIR" ] || [ -z "$(ls -A $PROJECT_BASE_DIR)" ]; then
        echo "No projects found."
        return
    fi

    # List directories
    local projects=($(ls -F "$PROJECT_BASE_DIR" | grep '/$' | tr -d '/'))
    
    for i in "${!projects[@]}"; do
        echo "$((i+1)). ${projects[$i]}"
    done
    
    echo ""
    read -p "Select Project (or Enter to back): " P_SEL
    if [ -z "$P_SEL" ]; then return; fi
    
    if ! [[ "$P_SEL" =~ ^[0-9]+$ ]] || [ "$P_SEL" -lt 1 ] || [ "$P_SEL" -gt "${#projects[@]}" ]; then
        echo "Invalid selection."
        return
    fi
    
    local selected_project="${projects[$((P_SEL-1))]}"
    local meta_path="$PROJECT_BASE_DIR/$selected_project/metadata.json"
    
    echo ""
    echo "--- Project: $selected_project ---"
    if [ -f "$meta_path" ]; then
        # Pretty print details using python
        python3 -c '
import sys, json
try:
    with open("'$meta_path'", "r") as f:
        data = json.load(f)
        src = data.get("source", "N/A")
        inst = data.get("install_date", "N/A")
        print(f"Source: {src}")
        print(f"Installed: {inst}")
        print("Services:")
        for s in data.get("services", []):
            name = s.get("name", "unknown")
            vmid = s.get("vmid", "unknown")
            print(f"  - {name} (VMID: {vmid})")
except Exception as e:
    print(f"Error reading metadata: {e}")
'
        # Check basic status of VMs? 
        # For now, just show listing.
    else
        echo "No metadata found."
    fi
    
    echo ""
    echo "Options:"
    echo "1. Update (Not Implemented)"
    echo "2. Delete (Not Implemented)"
    echo "3. Back"
    read -p "Select: " OPT
}

main_menu() {
    while true; do
        clear 2>/dev/null || echo ""
        echo "========================================"
        echo "   Proxmox Compose Manager (v0.2)       "
        echo "========================================"
        echo "1. Install New Project"
        echo "2. Manage Projects"
        echo "3. Exit"
        echo ""
        read -p "Select Option: " CHOICE
        
        case $CHOICE in
            1) 
                install_project
                read -p "Press Enter to return to menu..."
                ;;
            2) 
                manage_projects
                read -p "Press Enter to return to menu..."
                ;;
            3) 
                echo "Exiting."
                exit 0
                ;;
            *) 
                echo "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# --- Entry Point ---
main_menu
