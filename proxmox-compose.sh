#!/bin/bash

# Proxmox OCI Composer
# Reads a docker-compose.yml file and deploys services as OCI-based LXC containers on Proxmox VE 9.1+

# set -e


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

        print(f"{name}|{image}|{json.dumps(env)}|{json.dumps(volumes)}")

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
    
    # Detect extension to preserve (yml, yaml, json)
    # Default to .yml
    EXT="yml"
    if [[ "$INPUT_SOURCE" =~ \.yaml$ ]]; then EXT="yaml"; fi
    if [[ "$INPUT_SOURCE" =~ \.json$ ]]; then EXT="json"; fi

    local tmp_compose="$TMP_DIR/docker-compose.$EXT"
    
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
    
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.$EXT"
    cp "$tmp_compose" "$COMPOSE_FILE"
    
    # 3b. Interactive Edit
    if [ -t 0 ]; then
        echo "Opening compose file for review/edit..."
        read -p "Press Enter to open nano..."
        nano "$COMPOSE_FILE"
    else
        echo "Non-interactive mode detected. Skipping edit."
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
    
    echo "Project '$PROJECT_NAME' staged at $PROJECT_DIR"
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
    # 1. Project Ingestion
    _ingest_project
    # COMPOSE_FILE and PROJECT_NAME are now set. METADATA_FILE is set.

    # Check for Update Mode
    # If UPDATE_MODE is set, we try to load config and existing VMIDs
    declare -A EXISTING_VMIDS
    
    if [ "$UPDATE_MODE" = "true" ]; then
        echo "Running in Update Mode..."
        _load_project_config
        
        # Load existing VMIDs map AND Volumes map
        declare -A EXISTING_VOL_MAP
        
        # We process metadata to fill both maps
        # Output format: "VMID|name=id" or "VOL|source=volid"
        while IFS="|" read -r type data; do
            if [ "$type" == "VMID" ]; then
                IFS="=" read -r name id <<< "$data"
                EXISTING_VMIDS["$name"]="$id"
            elif [ "$type" == "VOL" ]; then
                # data is "source=volid"
                # Warning: source might contain '='? 
                # Let's rely on python to print cleaner split
                IFS="=" read -r src volid <<< "$data"
                EXISTING_VOL_MAP["$src"]="$volid"
            fi
        done < <(python3 - "$METADATA_FILE" <<'EOF'
import json, sys
print(f"DEBUG: Loading metadata from {sys.argv[1]}", file=sys.stderr)
try:
    with open(sys.argv[1], "r") as f:
        data = json.load(f)
    print(f"DEBUG: Found {len(data.get('services', []))} services", file=sys.stderr)
    for s in data.get("services", []):
        print(f"VMID|{s.get('name')}={s.get('vmid')}")
        for v in s.get("volumes", []):
             print(f"VOL|{v.get('source')}={v.get('volid')}")
except Exception as e:
    print(f"DEBUG: Error loading metadata: {e}", file=sys.stderr)
EOF
)
        # Debug print the map size
        echo "DEBUG: Existing VMIDs: ${#EXISTING_VMIDS[@]}"
        echo "DEBUG: Existing Vols: ${#EXISTING_VOL_MAP[@]}"
    fi

    # 2. Inputs for Deployment
    # Logic: If CONFIG_LOADED is true, verify variables, else prompt.
    
    # Node Selection
    if [ -z "$TARGET_NODE" ]; then
        echo "Available Nodes:"
        nodes=$(pvesh get /nodes --output-format json | python3 -c 'import sys, json; print("\n".join([n["node"] for n in json.load(sys.stdin)]))')
        echo "$nodes"
        read -p "Target Node: " TARGET_NODE
    else
        echo "Using Configured Node: $TARGET_NODE"
    fi

    # Template Storage
    if [ -z "$TEMPLATE_STORAGE" ]; then
        echo "Available Storages on $TARGET_NODE (supporting vztmpl):"
        pvesh get /nodes/$TARGET_NODE/storage --output-format json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for s in data:
    if "vztmpl" in s.get("content", ""):
        print(s["storage"])
'
        read -p "Target Template Storage ID: " TEMPLATE_STORAGE
    else
        echo "Using Configured Template Storage: $TEMPLATE_STORAGE"
    fi

    # RootFS Storage Selection
    if [ -z "$ROOTFS_STORAGE" ]; then
        echo "Available Storages for Containers (rootdir):"
        pvesh get /nodes/$TARGET_NODE/storage --output-format json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for s in data:
    if "rootdir" in s.get("content", ""):
        print(s["storage"])
'
        read -p "Target Container Storage ID: " ROOTFS_STORAGE
    else
        echo "Using Configured Container Storage: $ROOTFS_STORAGE"
    fi

    # Volume Storage (Virtual Disks)
    if [ -z "$VOL_STORAGE" ]; then
        read -p "Target Volume Storage ID (Content 'images' or 'rootdir') [$ROOTFS_STORAGE]: " VOL_STORAGE
        VOL_STORAGE=${VOL_STORAGE:-$ROOTFS_STORAGE}
    fi

    # Volume Size
    if [ -z "$VOL_SIZE" ]; then
        echo "Default Volume Size (e.g. 8G, 16G)."
        echo "Note: If using thin provisioning (LVM-Thin/ZFS), it is safe to oversize."
        read -p "Volume Size [16G]: " VOL_SIZE
        VOL_SIZE=${VOL_SIZE:-16G}
    fi

    # Network Bridge
    if [ -z "$NET_BRIDGE" ]; then
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
    else
         echo "Using Configured Bridge: $NET_BRIDGE"
    fi

    # Network Configuration (DHCP vs Static)
    if [ -z "$IP_CONFIG" ]; then
        read -p "IP Configuration (dhcp/static) [dhcp]: " IP_CONFIG
        IP_CONFIG=${IP_CONFIG:-dhcp}
        
        if [ "$IP_CONFIG" = "static" ]; then
            read -p "IPv4/CIDR (e.g. 192.168.1.10/24): " NET_CIDR
            read -p "Gateway (e.g. 192.168.1.1): " NET_GW
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

    # --- 2. Pull Image ---
    # Generate deterministic filename for the template
    # Replace non-alphanumeric chars with underscore, add .tar extension
    CLEAN_IMAGE_NAME=$(echo "$S_IMAGE" | tr -c 'a-zA-Z0-9.-' '_')
    TARGET_FILENAME_LESSTAR="pmxc_${CLEAN_IMAGE_NAME%?}"
    TARGET_FILENAME="pmxc_${CLEAN_IMAGE_NAME%?}.tar"
    
    echo "Pulling image '$S_IMAGE' to $TEMPLATE_STORAGE on $TARGET_NODE as '$TARGET_FILENAME'..."
    PULL_OUTPUT=$(pvesh create /nodes/$TARGET_NODE/storage/$TEMPLATE_STORAGE/oci-registry-pull --reference "$S_IMAGE" --filename "$TARGET_FILENAME_LESSTAR" 2>&1 || true)
    UPID=$(echo "$PULL_OUTPUT" | grep -o "UPID:.*" | tail -n 1)
    
    if [ -z "$UPID" ]; then
        if echo "$PULL_OUTPUT" | grep -q "refusing to override"; then
             echo "Image '$S_IMAGE' already exists as '$TARGET_FILENAME'. Skipping pull."
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
            # Interactive check only if possible, else fail
            echo "Assuming failure is fatal."
            exit 1
        else
            echo "Image pulled successfully."
        fi
    fi

    # --- 3. Locate Template ---
    # With explicit filename, we construct the ID directly
    TEMPLATE_VOLID="$TEMPLATE_STORAGE:vztmpl/$TARGET_FILENAME"
    echo "Using template: $TEMPLATE_VOLID"

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
        --features nesting=1 \
        --unprivileged 1 \
        --start 0 || { echo "Error: Failed to create container $CURRENT_VMID"; exit 1; }

    # --- 5. Post-Creation Volume Attachment (pct set) ---
    echo "Processing volumes..."
    MP_INDEX=0
    for VOL_ITEM in "${PENDING_VOLUMES[@]}"; do
        [ -z "$VOL_ITEM" ] && continue
        IFS='|' read -r V_TYPE V_SOURCE V_TARGET <<< "$VOL_ITEM"
        
        MOUNT_STR=""
        IS_NEW_ALLOCATION="false"
        PROXMOX_VOLID=""

        if [ "$V_TYPE" == "bind" ]; then
            # Bind Mount
            echo "Attaching bind mount: $V_SOURCE -> $V_TARGET"
            MOUNT_STR="$V_SOURCE,mp=$V_TARGET"
            PROXMOX_VOLID="$V_SOURCE" # For metadata
        else
            # Global Volume
            # 1. Check Existing (Update Mode from Metadata)
            if [ "$UPDATE_MODE" = "true" ] && [ -n "${EXISTING_VOL_MAP[$V_SOURCE]}" ]; then
                 PROXMOX_VOLID="${EXISTING_VOL_MAP[$V_SOURCE]}"
                 echo "Reusing existing volume '$V_SOURCE': $PROXMOX_VOLID"
                 GLOBAL_VOL_MAP[$V_SOURCE]="$PROXMOX_VOLID"
                 MOUNT_STR="$PROXMOX_VOLID,mp=$V_TARGET"
            
            # 2. Check Global Map (Current Session Shared)
            elif [[ -n "${GLOBAL_VOL_MAP[$V_SOURCE]}" ]]; then
                 PROXMOX_VOLID="${GLOBAL_VOL_MAP[$V_SOURCE]}"
                 echo "Attaching shared volume '$V_SOURCE': $PROXMOX_VOLID"
                 MOUNT_STR="$PROXMOX_VOLID,mp=$V_TARGET"
            
            # 3. Create New (pct set storage:size)
            else
                 echo "Creating new volume for '$V_SOURCE'..."
                 # Syntax: storage:size (size in GB, numeric only)
                 MOUNT_STR="$VOL_STORAGE:$CLEAN_VOL_SIZE,mp=$V_TARGET"
                 IS_NEW_ALLOCATION="true"
            fi
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
                
                if [ -z "$PROXMOX_VOLID" ]; then
                    echo "Error: Failed to identify new volume ID for $V_SOURCE"
                    exit 1
                fi
                echo "Identified new volume: $PROXMOX_VOLID"
                GLOBAL_VOL_MAP[$V_SOURCE]="$PROXMOX_VOLID"
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
    CONF_FILE="/etc/pve/lxc/${CURRENT_VMID}.conf"
    echo "Setting environment variables..."
    echo "$S_ENV_JSON" | python3 -c "
import sys, json
env = json.load(sys.stdin)
for k, v in env.items():
    print(f'lxc.environment.runtime: {k}={v}')
" >> "$CONF_FILE"
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
    echo "1. Update Project"
    echo "2. Delete (Not Implemented)"
    echo "3. Back"
    read -p "Select: " OPT
    
    case $OPT in
        1)
            update_project "$selected_project"
            ;;
    esac
}

update_project() {
    local p_name="$1"
    local p_dir="$PROJECT_BASE_DIR/$p_name"
    METADATA_FILE="$p_dir/metadata.json"
    
    echo "Updating project '$p_name'..."
    
    # 1. Load Config & Verify
    _load_project_config
    if [ "$CONFIG_LOADED" != "true" ]; then
        echo "Error: Project configuration not found in metadata. Cannot auto-update."
        read -p "Press Enter to continue..."
        return
    fi
    
    # 2. Confirm
    echo "This will:"
    echo "  - Stop and DESTROY existing containers for '$p_name'."
    echo "  - Pull the latest compose file."
    echo "  - Re-deploy services using the SAME VMIDs."
    echo "  - Persistent volumes (Global/Bind) will be preserved."
    read -p "Are you sure? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then return; fi
    
    # 3. Destroy Existing
    echo "Destroying existing resources..."
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
            
            echo "Detaching volumes from $vmid..."
            # Detach mp0 through mp9 (assuming max 10 volumes for now)
            # We could parse config, but unconditional detach attempt is safer/easier
            IDS=""
            for i in {0..9}; do IDS="$IDS --delete mp$i"; done
            pct set $vmid $IDS 2>/dev/null || true
            
            echo "Destroying container $vmid..."
            pct destroy $vmid --purge || echo "Warning: Failed to destroy $vmid"
        fi
    done
    
    # 4. Re-Install
    export UPDATE_MODE="true"
    # We must reset PROJECT_DIR/NAME context for ingest
    # Actually ingest expects interactive input...
    # We can fake it or modify ingest.
    # Current ingest prompts for URL. In update, we might want to reuse source?
    # Let's reuse source from metadata.
    
    SOURCE=$(python3 -c '
import json
with open("'$METADATA_FILE'", "r") as f:
    print(json.load(f).get("source", ""))
')
    if [ -z "$SOURCE" ]; then
        echo "Source not found in metadata."
        # Fallback to prompt
    else
        # Feed source to ingest
        # We can simulate input via pipe if we want to reuse _ingest
        # Or set var? _ingest reads INPUT_SOURCE.
        # Let's echo checking.
        echo "Re-ingesting from source: $SOURCE"
    fi
    
    # We need to feed the source to invalid read.
    # "read -p ... INPUT_SOURCE"
    # Hack: Pre-fill input buffer or modifying ingest to take arg?
    # Let's modify ingest to check arg.
    # OR, simple hack:
    
    # Feed source and confirmation to install_project
    # 1. Source URL/File
    # 2. 'y' for "Update/Reinstall?" prompt in ingest
    # 3. 'n' for "Update/Reinstall?" (Wait, ingest asks "Update/Reinstall?". Yes. We say y.)
    # 4. If ingest failed to find name, it might ask for name. (Assume not needed)
    
    { echo "$SOURCE"; echo "y"; } | install_project
    
    # Clean up
    unset UPDATE_MODE
    read -p "Update complete. Press Enter..."
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
