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
# Set by the CLI's -y/--yes: no prompts; missing settings are errors.
ASSUME_YES="false"

# Error handling and rollback
cleanup_on_error() {
    local exit_code=$?
    # Only run rollback if we have created VMs and exit was not clean
    if [ $exit_code -ne 0 ] && [ ${#created_vmids[@]} -gt 0 ]; then
        echo ""
        tui_msg "Installation Failed!"
        if [ "$ASSUME_YES" = "true" ] || tui_yesno "Installation failed. Rollback/Cleanup created containers (${created_vmids[*]})?"; then
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
    if [ "$ASSUME_YES" = "true" ] || [ ! -t 0 ]; then
        echo -e "$1"
    else
        whiptail --title "Proxmox Compose" --msgbox "$1" 10 60
    fi
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
# Parses the compose file (with .env / env_file / ${VAR} interpolation) and
# prints one tab-separated line per service (JSON never contains raw tabs):
#   NAME  IMAGE  ENV_JSON  VOLUMES_JSON  OPTIONS_JSON
# OPTIONS_JSON holds runtime settings: command, entrypoint (lists or null),
# user, shm_size (bytes), onboot, cores, memory, swap (MB), rootfs_size (GB).
# Exits non-zero (with a message) on a missing required variable.
parse_compose() {
    python3 - "$COMPOSE_FILE" <<'EOF'
import json, math, os, re, shlex, sys
import yaml

compose_path = sys.argv[1]
base_dir = os.path.dirname(os.path.abspath(compose_path))

def fail(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)

def parse_dotenv(path):
    """KEY=VALUE lines; supports comments, `export`, single/double quotes."""
    values = {}
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            key, sep, val = line.partition("=")
            key = key.strip()
            if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", key):
                continue
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
                quote, val = val[0], val[1:-1]
                if quote == '"':
                    val = val.replace('\\"', '"').replace("\\\\", "\\")
            else:
                val = re.sub(r"\s+#.*$", "", val)  # inline comment
            values[key] = val
    return values

# Interpolation source: .env next to the compose file, overridden by the
# shell environment (compose precedence).
dotenv_path = os.path.join(base_dir, ".env")
interp_env = parse_dotenv(dotenv_path) if os.path.isfile(dotenv_path) else {}
interp_env.update(os.environ)

def interpolate(s, where):
    """Compose-spec interpolation: $$, $VAR, ${VAR}, ${VAR:-d}, ${VAR-d},
    ${VAR:?e}, ${VAR?e}, ${VAR:+a}, ${VAR+a}; defaults may nest."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c != "$":
            out.append(c); i += 1; continue
        if i + 1 < n and s[i + 1] == "$":
            out.append("$"); i += 2; continue
        if i + 1 < n and s[i + 1] == "{":
            depth, j = 1, i + 2
            while j < n and depth:
                if s[j] == "{" and s[j - 1] == "$":
                    depth += 1
                elif s[j] == "}":
                    depth -= 1
                j += 1
            if depth:
                fail(f"unterminated '${{' in {where}: {s}")
            expr = s[i + 2:j - 1]
            m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])(.*))?", expr, re.S)
            if not m:
                fail(f"invalid interpolation '${{{expr}}}' in {where}")
            name, op, arg = m.group(1), m.group(2), m.group(3) or ""
            val = interp_env.get(name)
            unset_or_empty = val is None or val == ""
            if op is None:
                out.append(val or "")
            elif op in (":-", "-"):
                use_default = unset_or_empty if op == ":-" else val is None
                out.append(interpolate(arg, where) if use_default else val)
            elif op in (":?", "?"):
                missing = unset_or_empty if op == ":?" else val is None
                if missing:
                    fail(f"required variable {name} is not set ({interpolate(arg, where) or 'no message'}) in {where}. Add it to {dotenv_path}")
                out.append(val)
            else:  # :+ / +
                present = not unset_or_empty if op == ":+" else val is not None
                out.append(interpolate(arg, where) if present else "")
            i = j
            continue
        m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)", s[i:])
        if m:
            out.append(interp_env.get(m.group(1), "")); i += len(m.group(0)); continue
        out.append(c); i += 1
    return "".join(out)

def walk(node, where):
    if isinstance(node, str):
        return interpolate(node, where)
    if isinstance(node, list):
        return [walk(x, where) for x in node]
    if isinstance(node, dict):
        return {k: walk(v, f"{where}.{k}") for k, v in node.items()}
    return node

def as_str(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)

def as_cmd(v):
    if v is None:
        return None
    if isinstance(v, str):
        return shlex.split(v)
    return [as_str(x) for x in v]

def duration(v, default):
    """Compose duration ("1m30s", "10s", "500ms", or seconds) -> seconds."""
    if v is None:
        return default
    if isinstance(v, (int, float)):
        return float(v)
    total, found = 0.0, False
    for num, unit in re.findall(r"([\d.]+)(ms|us|ns|h|m|s)", str(v)):
        found = True
        total += float(num) * {"h": 3600, "m": 60, "s": 1, "ms": 0.001, "us": 1e-6, "ns": 1e-9}[unit]
    if not found:
        fail(f"invalid duration '{v}'")
    return total

def size_bytes(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    m = re.fullmatch(r"\s*([\d.]+)\s*([kmgt]?)i?b?\s*", str(v), re.I)
    if not m:
        fail(f"invalid size '{v}'")
    return int(float(m.group(1)) * 1024 ** "bkmgt".index((m.group(2) or "b").lower()))

try:
    with open(compose_path) as f:
        data = yaml.safe_load(f)
except Exception as e:
    fail(f"parsing yaml: {e}")
if not data or "services" not in data:
    fail("No services found in compose file")

for name, service in data["services"].items():
    service = walk(service or {}, f"services.{name}")
    image = service.get("image")
    if not image:
        print(f"Warning: Service {name} has no image defined. Skipping.", file=sys.stderr)
        continue

    # env_file first, then environment (environment wins)
    env = {}
    env_files = service.get("env_file") or []
    if isinstance(env_files, (str, dict)):
        env_files = [env_files]
    for ef in env_files:
        path, required = (ef.get("path"), ef.get("required", True)) if isinstance(ef, dict) else (ef, True)
        full = os.path.join(base_dir, path)
        if os.path.isfile(full):
            env.update(parse_dotenv(full))
        elif required:
            fail(f"env_file '{path}' for service {name} not found (expected at {full})")

    raw_env = service.get("environment") or {}
    if isinstance(raw_env, list):
        for item in raw_env:
            k, sep, v = as_str(item).partition("=")
            if sep:
                env[k] = v
            elif k in interp_env:  # "KEY" alone passes the value through
                env[k] = interp_env[k]
    else:
        for k, v in raw_env.items():
            if v is None:
                if k in interp_env:
                    env[k] = interp_env[k]
            else:
                env[k] = as_str(v)

    # Volumes
    volumes = []
    for v in service.get("volumes") or []:
        if isinstance(v, str):
            parts = v.split(":")
            source = parts[0]
            target = parts[1] if len(parts) > 1 else source
            ro = len(parts) > 2 and "ro" in parts[2].split(",")
            v_type = "bind" if source.startswith((".", "/", "~")) else "global"
            volumes.append({"type": v_type, "source": source, "target": target, "ro": ro})
        elif isinstance(v, dict):
            source, target = v.get("source"), v.get("target")
            v_type = "bind" if v.get("type") == "bind" or str(source).startswith((".", "/", "~")) else "global"
            if source and target:
                volumes.append({"type": v_type, "source": source, "target": target, "ro": bool(v.get("read_only"))})

    # Startup dependencies and healthcheck
    dep = service.get("depends_on") or {}
    if isinstance(dep, list):
        depends_on = {d: "service_started" for d in dep}
    else:
        depends_on = {d: (c or {}).get("condition", "service_started") for d, c in dep.items()}
    health = None
    hc = service.get("healthcheck") or {}
    if hc and not hc.get("disable"):
        test = hc.get("test")
        cmd = None
        if isinstance(test, str):
            cmd = ["sh", "-c", test]
        elif isinstance(test, list) and test:
            if test[0] == "CMD":
                cmd = [as_str(x) for x in test[1:]]
            elif test[0] == "CMD-SHELL":
                cmd = ["sh", "-c", " ".join(as_str(x) for x in test[1:])]
        if cmd:
            health = {"cmd": cmd, "interval": duration(hc.get("interval"), 30),
                      "timeout": duration(hc.get("timeout"), 30), "retries": int(hc.get("retries", 3)),
                      "start_period": duration(hc.get("start_period"), 0)}

    # Runtime options
    limits = ((service.get("deploy") or {}).get("resources") or {}).get("limits") or {}
    pmxc = service.get("x-pmxc") or {}
    mem = pmxc.get("memory") or service.get("mem_limit") or limits.get("memory")
    cpus = pmxc.get("cores") or service.get("cpus") or limits.get("cpus")
    restart = as_str(service.get("restart")) if "restart" in service else None
    opts = {
        "command": as_cmd(service.get("command")),
        "entrypoint": as_cmd(service.get("entrypoint")),
        "user": as_str(service.get("user")) if service.get("user") is not None else None,
        "shm_size": size_bytes(service.get("shm_size")),
        "onboot": None if restart is None else (0 if restart == "no" else 1),
        "cores": max(1, math.ceil(float(cpus))) if cpus else None,
        "memory": (int(mem) if isinstance(mem, int) and mem < 1 << 20 else size_bytes(mem) // (1 << 20)) if mem else None,
        "swap": pmxc.get("swap"),
        "rootfs_size": pmxc.get("rootfs_size"),
        "ip": pmxc.get("ip"),
        "vmid": pmxc.get("vmid"),
        "container_name": service.get("container_name"),
        "depends_on": depends_on,
        "healthcheck": health,
    }
    if pmxc.get("memory") and not isinstance(pmxc["memory"], int):
        opts["memory"] = size_bytes(pmxc["memory"]) // (1 << 20)

    for k, v in env.items():
        if re.search(r"[\x00-\x08\x0a-\x1f\x7f]", v):
            fail(f"environment variable {k} of service {name} contains control characters (e.g. a newline); PVE cannot store that")
    print(f"{name}\t{image}\t{json.dumps(env)}\t{json.dumps(volumes)}\t{json.dumps(opts)}")
EOF
}

# Fill the SERVICES array from the compose file; returns 1 (after printing
# the parser's error) if the compose file can't be fully resolved.
load_services() {
    local out
    SERVICES=()
    if ! out=$(parse_compose); then
        return 1
    fi
    [ -n "$out" ] && mapfile -t SERVICES <<< "$out"
    return 0
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
declare -A PULLED_TEMPLATES
_pull_image() {
    local image="$1"
    local base="$(_template_prefix "$image")_$(date +%Y%m%d-%H%M%S)"
    TEMPLATE_VOLID=""
    if [ -n "${PULLED_TEMPLATES[$image]}" ]; then
        TEMPLATE_VOLID="${PULLED_TEMPLATES[$image]}"
        echo "Using image '$image' pulled earlier in this run: $TEMPLATE_VOLID"
        return 0
    fi

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
    PULLED_TEMPLATES[$image]="$TEMPLATE_VOLID"
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

# Print shell assignments (OPT_CORES, OPT_MEMORY, OPT_SWAP, OPT_ONBOOT,
# OPT_ROOTFS_SIZE) for the resource options of a service; unset ones are empty.
_opts_shell() {
    python3 - "$1" <<'EOF2'
import json, shlex, sys
o = json.loads(sys.argv[1] or "{}")
for key in ("cores", "memory", "swap", "onboot", "rootfs_size"):
    v = o.get(key)
    print(f"OPT_{key.upper()}={shlex.quote('' if v is None else str(int(v)))}")
EOF2
}

# Filesystem path of a template volid ("" if it doesn't exist).
_template_path() {
    [ -z "$1" ] && return
    local path
    path=$(pvesm path "$1" 2>/dev/null) && [ -f "$path" ] && echo "$path"
}

# Set a (stopped) container's runtime settings: environment, entrypoint and
# lxc.init.* user/cwd.
#
# PVE builds these from the OCI image config when a container is created and
# stores them in <vmid>.conf, where they persist and can be customised
# (e.g. entrypoint "dumb-init -- ak worker"). When a container is rebuilt from
# a newer image, settings that differ from what PVE generated from the *old*
# image are customisations and are carried over; everything else follows the
# new image. Compose environment values always win.
#
# Compose `command` / `entrypoint` / `user` / `shm_size` (options JSON from
# parse_compose) take precedence over both image defaults and kept values.
#
# Args: vmid, old config file ("" for a fresh install), old template path
# ("" if unknown), new template path, compose env JSON, compose options JSON.
# The env list is written directly as lxc.environment.runtime lines (the
# format PVE stores it in); the NUL-separated `env` option can't be passed
# on a command line.
_apply_runtime() {
    python3 - "$@" <<'EOF'
import json, shlex, sys, tarfile

vmid, old_conf_path, old_tmpl, new_tmpl, compose_env_json = sys.argv[1:6]
opts = json.loads((sys.argv[6] if len(sys.argv) > 6 else "") or "{}")
compose_sets_entrypoint = opts.get("command") is not None or opts.get("entrypoint") is not None
compose_sets_user = opts.get("user") is not None
conf_path = f"/etc/pve/lxc/{vmid}.conf"

def oci_config(path):
    if not path:
        return None
    try:
        with tarfile.open(path) as t:
            blob = lambda d: json.load(t.extractfile("blobs/" + d.replace(":", "/", 1)))
            man = blob(json.load(t.extractfile("index.json"))["manifests"][0]["digest"])
            if "manifests" in man:  # nested image index
                man = blob(man["manifests"][0]["digest"])
            return blob(man["config"]["digest"]).get("config") or {}
    except Exception as e:
        print(f"NOTE\tcould not read image config from {path}: {e}")
        return None

def env_dict(entries):
    d = {}
    for e in entries or []:
        k, _, v = e.partition("=")
        d[k] = v
    return d

def default_entrypoint(cfg):
    # Mirrors PVE::LXC::Create::restore_oci_archive
    cmd = (cfg.get("Entrypoint") or []) + (cfg.get("Cmd") or [])
    return cmd if cmd and cmd[0] != "/sbin/init" else None

def default_init(cfg):
    # lxc.init.* values PVE derives from the image; None = can't tell (named user)
    d = {"lxc.init.cwd": cfg.get("WorkingDir") or None}
    user = cfg.get("User") or ""
    if not user:
        d.update({"lxc.init.uid": None, "lxc.init.gid": None, "lxc.init.groups": None})
    else:
        u, _, g = user.partition(":")
        if u.isdigit() and (not g or g.isdigit()):
            d["lxc.init.uid"] = u
            if g:
                d["lxc.init.gid"] = g
    return d

def read_main(path):
    """(lines, main_len): config lines and the length of the main section."""
    with open(path) as f:
        lines = f.read().split("\n")
    n = next((i for i, l in enumerate(lines) if l.startswith("[")), len(lines))
    return lines, n

def settings(lines):
    entrypoint, env, init = None, [], {}
    for l in lines:
        key, _, val = l.partition(":")
        key, val = key.strip(), val.strip()
        if key == "entrypoint":
            entrypoint = val
        elif key == "lxc.environment.runtime":
            env.append(val)
        elif key.startswith("lxc.init."):
            init[key] = val
    return entrypoint, env_dict(env), init

old_cfg = oci_config(old_tmpl)
new_cfg = oci_config(new_tmpl) or {}
compose_env = json.loads(compose_env_json or "{}")

lines, main_len = read_main(conf_path)
main, rest = lines[:main_len], lines[main_len:]
new_entrypoint, new_env, new_init = settings(main)
# The freshly created config already holds the new image's env; prefer the
# image config itself when readable so ordering follows the image.
if new_cfg.get("Env"):
    new_env = env_dict(new_cfg["Env"])

final_env = dict(new_env)
set_entrypoint = None
final_init = dict(new_init)

if old_conf_path:
    old_lines, old_len = read_main(old_conf_path)
    old_entrypoint, old_env, old_init = settings(old_lines[:old_len])

    if old_cfg is not None:
        # Entrypoint: keep it only if it was customised
        default = default_entrypoint(old_cfg)
        try:
            customised = (shlex.split(old_entrypoint) if old_entrypoint else None) != default
        except ValueError:
            customised = True
        if customised and old_entrypoint and not compose_sets_entrypoint:
            set_entrypoint = old_entrypoint
            print(f"KEPT\tcustom entrypoint: {old_entrypoint}")
            new_default = default_entrypoint(new_cfg)
            if new_default != default:
                show = lambda c: shlex.join(c) if c else "/sbin/init"
                print(f"WARN\tthe image changed its default entrypoint from '{show(default)}' to "
                      f"'{show(new_default)}'. Your custom entrypoint was kept; check that it still "
                      f"works (pct set {vmid} --entrypoint ...)")
        # Env: keep values that differ from the old image's defaults
        old_img_env = env_dict(old_cfg.get("Env"))
        for k, v in old_env.items():
            if old_img_env.get(k) != v:
                final_env[k] = v
        # lxc.init.*: keep values that differ from the old image's defaults
        defaults = default_init(old_cfg)
        for k, v in old_init.items():
            if k in defaults and defaults[k] != v:
                final_init[k] = v
                if not (compose_sets_user and k in ("lxc.init.uid", "lxc.init.gid")):
                    print(f"KEPT\tcustom {k}: {v}")
    else:
        # Old image unknown: can't tell defaults from customisations.
        # Keep the entrypoint and init user/cwd (changing them can break the
        # service or file ownership); let the new image own the env keys it sets.
        if old_entrypoint:
            set_entrypoint = old_entrypoint
        final_init.update(old_init)
        replaced = []
        for k, v in old_env.items():
            if k in new_env:
                if new_env[k] != v:
                    replaced.append(k)
            else:
                final_env[k] = v
        print("NOTE\told image config unavailable: kept the previous entrypoint and init user/cwd as-is"
              + (f"; took the new image's value for: {' '.join(replaced)}" if replaced else ""))

final_env.update({k: "" if v is None else str(v) for k, v in compose_env.items()})

# Compose runtime options
set_shm = None
if compose_sets_entrypoint:
    # Compose semantics: entrypoint replaces the image Entrypoint and drops its
    # Cmd; command replaces the Cmd.
    ep = opts["entrypoint"] if opts.get("entrypoint") is not None else (new_cfg.get("Entrypoint") or [])
    if opts.get("command") is not None:
        cmd = opts["command"]
    else:
        cmd = [] if opts.get("entrypoint") is not None else (new_cfg.get("Cmd") or [])
    if ep + cmd:
        set_entrypoint = shlex.join(ep + cmd)
        print(f"SET\tentrypoint from compose: {set_entrypoint}")
if opts.get("user") is not None:
    u, _, g = opts["user"].partition(":")
    ids = {"root": "0"}
    u, g = ids.get(u, u), ids.get(g, g)
    if u.isdigit() and (not g or g.isdigit()):
        final_init["lxc.init.uid"] = u
        final_init["lxc.init.gid"] = g or ("0" if u == "0" else final_init.get("lxc.init.gid"))
        print(f"SET\tuser from compose: {u}{':' + final_init['lxc.init.gid'] if final_init.get('lxc.init.gid') else ''}")
    else:
        print(f"WARN\tcompose user '{opts['user']}' is not numeric (or root); set lxc.init.uid/gid by hand")
if opts.get("shm_size"):
    mib = max(1, opts["shm_size"] // (1 << 20))
    set_shm = f"lxc.mount.entry: tmpfs dev/shm tmpfs rw,nosuid,nodev,create=dir,size={mib}m 0 0"

out = []
for l in main:
    key = l.partition(":")[0].strip()
    if key == "lxc.environment.runtime" or key.startswith("lxc.init."):
        continue
    if set_shm and key == "lxc.mount.entry" and " dev/shm " in l:
        continue
    if key == "entrypoint" and set_entrypoint is not None:
        l = f"entrypoint: {set_entrypoint}"
    out.append(l)
while out and out[-1] == "":
    out.pop()
if set_entrypoint is not None and not any(l.startswith("entrypoint:") for l in out):
    out.append(f"entrypoint: {set_entrypoint}")
out += [f"{k}: {v}" for k, v in final_init.items() if v is not None]
if set_shm:
    out.append(set_shm)
out += [f"lxc.environment.runtime: {k}={v}" for k, v in final_env.items()]
with open(conf_path, "w") as f:
    f.write("\n".join(out + ([""] + rest if rest else [""])))
EOF
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
    if [ -n "$1" ]; then
        INPUT_SOURCE="$1"
    else
        if ! tui_input "Enter Compose File Path or URL:" "docker-compose.yml" INPUT_SOURCE; then return 1; fi
        INPUT_SOURCE=${INPUT_SOURCE:-docker-compose.yml}
    fi
    
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
        tui_msg "Error: Project '$PROJECT_NAME' already exists. Use Manage Projects -> Update (or '$0 update $PROJECT_NAME')."
        exit 1
    else
        mkdir -p "$PROJECT_DIR"
    fi
    
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.$EXT"
    cp "$tmp_compose" "$COMPOSE_FILE"

    # A local compose file brings its .env and env_file files along
    if [[ ! "$INPUT_SOURCE" =~ ^https?:// ]]; then
        local src_dir f
        src_dir=$(dirname "$(readlink -f "$INPUT_SOURCE")")
        while read -r f; do
            [ -z "$f" ] && continue
            if [ -f "$src_dir/$f" ] && [ ! -e "$PROJECT_DIR/$f" ]; then
                mkdir -p "$(dirname "$PROJECT_DIR/$f")"
                cp "$src_dir/$f" "$PROJECT_DIR/$f"
                echo "Copied $f into the project"
            fi
        done < <(python3 - "$COMPOSE_FILE" <<'EOF2'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
files = {".env"}
for svc in (data.get("services") or {}).values():
    ef = (svc or {}).get("env_file") or []
    for e in ([ef] if isinstance(ef, (str, dict)) else ef):
        path = e.get("path") if isinstance(e, dict) else e
        if path and not path.startswith("/") and ".." not in path.split("/"):
            files.add(path)
print("\n".join(sorted(files)))
EOF2
)
    fi
    
    # 3b. Interactive Edit
    if [ -t 0 ] && [ "$ASSUME_YES" != "true" ]; then
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
    python3 - "$METADATA_FILE" "$TARGET_NODE" "$TEMPLATE_STORAGE" "$ROOTFS_STORAGE" "$VOL_STORAGE" "$VOL_SIZE" "$NET_BRIDGE" "$IP_CONFIG" "$NET_CIDR" "$NET_GW" "$NET_TAG" "$DATA_DIR" <<'EOF'
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
    "net_gw": sys.argv[10],
    "net_tag": sys.argv[11],
    "data_dir": sys.argv[12]
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
        print(f'NET_TAG="{cfg.get("net_tag", "")}"')
        print(f'DATA_DIR="{cfg.get("data_dir", "")}"')
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



# Print shell assignments for the project settings in the compose file's
# top-level `x-pmxc` block (values are taken literally, not interpolated):
#   node, template_storage, rootfs_storage, volume_storage, volume_size,
#   bridge, tag, ip ("dhcp" or the first service's CIDR), gateway, vmid
_project_defaults_shell() {
    python3 - "$COMPOSE_FILE" <<'EOF'
import shlex, sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
x = data.get("x-pmxc") or {}
out = {
    "TARGET_NODE": x.get("node"), "TEMPLATE_STORAGE": x.get("template_storage"),
    "ROOTFS_STORAGE": x.get("rootfs_storage"), "VOL_STORAGE": x.get("volume_storage"),
    "VOL_SIZE": x.get("volume_size"), "NET_BRIDGE": x.get("bridge"), "NET_TAG": x.get("tag"),
    "NET_GW": x.get("gateway"), "START_VMID": x.get("vmid"), "DATA_DIR": x.get("data_dir"),
}
ip = x.get("ip")
if ip:
    if str(ip).lower() == "dhcp":
        out["IP_CONFIG"] = "dhcp"
    else:
        out["IP_CONFIG"], out["NET_CIDR"] = "static", ip
for k, v in out.items():
    if v is not None:
        print(f"{k}={shlex.quote(str(v))}")
EOF
}

# In non-interactive mode a setting that would need a prompt is an error.
_require_setting() {
    if [ "$ASSUME_YES" = "true" ]; then
        echo "Error: x-pmxc.$1 must be set in the compose file for a non-interactive install."
        return 1
    fi
}

# Decide how every compose volume is provided (all services at once, since
# sharing matters). Prints tab-separated lines:
#   VOL <service> <kind> <source> <target> <host path or "-"> <ro 0|1>
#     kind: volume (new PVE volume, backed up with the CT)
#           bind   (existing absolute host path)
#           shared (host directory under DATA_DIR, used by several services)
#           missing (update only: absolute host path that doesn't exist; fine
#                    if the container already provides that mount point)
#   SKIP <service> <source> <reason>
#   ERROR <message>
# Arg: "install" (missing host paths are errors) or "update".
_plan_volumes() {
    printf '%s\n' "${SERVICES[@]}" > "$TMP_DIR/services.tsv"
    python3 - "$TMP_DIR/services.tsv" "$DATA_DIR" "${1:-install}" <<'EOF'
import json, os, sys
services_file, data_dir, mode = sys.argv[1:4]
rows = []
for line in open(services_file).read().splitlines():
    if line.strip():
        name, _img, _env, vols, _opts = line.split("\t")
        rows.append((name, json.loads(vols)))

def key(v):
    src = os.path.expanduser(v["source"])
    if src.startswith("/"):
        return None
    return os.path.normpath(src).lstrip("./") or "root"

users = {}
for name, vols in rows:
    for v in vols:
        k = key(v)
        if k:
            users.setdefault(k, set()).add(name)

errors = []
for name, vols in rows:
    for v in vols:
        src, tgt, ro = v["source"], v["target"], "1" if v.get("ro") else "0"
        k = key(v)
        if k is None:
            path = os.path.expanduser(src)
            if os.path.basename(path) == "docker.sock":
                print(f"SKIP\t{name}\t{src}\tthere is no Docker on a Proxmox host")
            elif os.path.exists(path):
                print(f"VOL\t{name}\tbind\t{src}\t{tgt}\t{path}\t{ro}")
            elif mode == "update":
                print(f"VOL\t{name}\tmissing\t{src}\t{tgt}\t{path}\t{ro}")
            else:
                errors.append(f"service {name}: host path {path} does not exist (create it, or use a relative path / named volume)")
        elif len(users[k]) > 1:
            print(f"VOL\t{name}\tshared\t{src}\t{tgt}\t{os.path.join(data_dir, k)}\t{ro}")
        else:
            print(f"VOL\t{name}\tvolume\t{src}\t{tgt}\t-\t{ro}")
for e in errors:
    print(f"ERROR\t{e}")
EOF
}

# Bind mounts into unprivileged containers are made as a mapped uid, so every
# directory above a bind-mounted path must be traversable by "other" (o+x),
# or the container fails to start.
_check_traversable() {
    local d="$1" blocked=""
    while [ "$d" != "/" ] && [ -n "$d" ]; do
        [ $(( $(stat -c %a "$d") % 10 & 1 )) -eq 1 ] || blocked="$blocked\n$d"
        d=$(dirname "$d")
    done
    if [ -n "$blocked" ]; then
        tui_msg "Error: $1 can't be bind-mounted into unprivileged containers because these directories are not world-traversable (o+x):$blocked\n\nUse another location (PMXC_BASE_DIR / x-pmxc.data_dir) or fix the permissions."
        return 1
    fi
}

# Attach one planned volume to a (stopped) container as mp<index>.
# Prints the new PVE volid for kind "volume".
_attach_volume() {
    local vmid="$1" index="$2" kind="$3" target="$4" host_path="$5" ro="$6"
    local opts="mp=$target${ro:+$( [ "$ro" = "1" ] && echo ",ro=1")}"
    case "$kind" in
        volume)
            pct set "$vmid" "-mp$index" "$VOL_STORAGE:$(echo "$VOL_SIZE" | tr -cd '0-9'),$opts" >/dev/null || return 1
            pct config "$vmid" | sed -n -E "s/^mp$index: ([^,]+).*/\1/p"
            ;;
        bind|shared)
            pct set "$vmid" "-mp$index" "$host_path,$opts" >/dev/null || return 1
            ;;
    esac
}

# Make new shared directories writable by the containers that use them:
# owned by the first non-root init user among them (mapped to the host uid).
_own_shared_dirs() {
    local dir svc vmid uid gid best_uid best_gid base
    for dir in "${NEW_SHARED_DIRS[@]}"; do
        best_uid="" best_gid=""
        for svc in ${SHARED_USERS[$dir]}; do
            vmid="${SVC_VMID[$svc]}"
            uid=$(sed -n 's/^lxc.init.uid: //p' "/etc/pve/lxc/$vmid.conf" | head -n 1)
            gid=$(sed -n 's/^lxc.init.gid: //p' "/etc/pve/lxc/$vmid.conf" | head -n 1)
            uid="${uid:-0}"
            if [ -z "$best_uid" ] || { [ "$best_uid" = "0" ] && [ "$uid" != "0" ]; }; then
                best_uid="$uid" best_gid="${gid:-$uid}"
            fi
        done
        base=$(sed -n -E 's/^lxc.idmap: u 0 ([0-9]+) .*/\1/p' "/etc/pve/lxc/${SVC_VMID[${SHARED_USERS[$dir]%% *}]}.conf" | head -n 1)
        base="${base:-100000}"
        chown "$((base + ${best_uid:-0})):$((base + ${best_gid:-0}))" "$dir"
        chmod 2775 "$dir"
        echo "Shared volume $dir owned by container uid ${best_uid:-0}"
    done
}

# Print service names in dependency order (dependencies first). Fails on
# unknown dependencies or cycles.
_service_order() {
    printf '%s\n' "${SERVICES[@]}" > "$TMP_DIR/services.tsv"
    python3 - "$TMP_DIR/services.tsv" <<'EOF'
import json, sys
deps, names = {}, []
for line in open(sys.argv[1]).read().splitlines():
    if line.strip():
        name, _i, _e, _v, opts = line.split("\t")
        names.append(name)
        deps[name] = list((json.loads(opts).get("depends_on") or {}).keys())
order, state = [], {}
def visit(n, path):
    if state.get(n) == "done":
        return
    if state.get(n) == "visiting":
        print(f"Error: dependency cycle: {' -> '.join(path + [n])}", file=sys.stderr)
        sys.exit(1)
    if n not in deps:
        print(f"Error: service {path[-1]} depends on unknown service {n}", file=sys.stderr)
        sys.exit(1)
    state[n] = "visiting"
    for d in deps[n]:
        visit(d, path + [n])
    state[n] = "done"
    order.append(n)
for n in names:
    visit(n, [])
print("\n".join(order))
EOF
}

# Run a service's compose healthcheck inside its container until it passes,
# honouring start_period / interval / retries / timeout.
# The check gets the container's runtime environment (pct exec doesn't).
_wait_healthy() {
    local name="$1" vmid="$2" opts="$3"
    local spec
    spec=$(python3 - "$opts" "/etc/pve/lxc/$vmid.conf" <<'EOF'
import json, shlex, sys
h = json.loads(sys.argv[1] or "{}").get("healthcheck")
if not h:
    sys.exit(0)
env = []
for line in open(sys.argv[2]):
    if line.startswith("["):
        break
    if line.startswith("lxc.environment.runtime:"):
        env.append(line.split(":", 1)[1].strip())
cmd = ["env", "-i"] + env + h["cmd"]
print(f"HC_CMD={shlex.quote(shlex.join(cmd))}")
print(f"HC_INTERVAL={max(1, int(h['interval']))}")
print(f"HC_TIMEOUT={max(1, int(h['timeout']))}")
print(f"HC_RETRIES={max(1, h['retries'])}")
print(f"HC_START={int(h['start_period'])}")
EOF
)
    if [ -z "$spec" ]; then
        echo "Note: $name has no healthcheck; treating 'running' as healthy"
        _wait_running "$vmid" 60
        return
    fi
    local HC_CMD HC_INTERVAL HC_TIMEOUT HC_RETRIES HC_START
    eval "$spec"
    echo "Waiting for $name to become healthy..."
    local deadline=$(( $(date +%s) + HC_START + HC_RETRIES * (HC_INTERVAL + HC_TIMEOUT) + 30 ))
    local failures=0 started
    started=$(date +%s)
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # shellcheck disable=SC2086
        if eval "timeout $HC_TIMEOUT pct exec $vmid -- $HC_CMD" >/dev/null 2>&1; then
            echo "$name is healthy"
            return 0
        fi
        # failures during start_period don't count
        if [ $(( $(date +%s) - started )) -ge "$HC_START" ]; then
            failures=$((failures + 1))
            [ "$failures" -ge "$HC_RETRIES" ] && break
        fi
        sleep "$HC_INTERVAL"
    done
    echo "Warning: $name did not become healthy"
    return 1
}

_wait_running() {
    local vmid="$1" limit="${2:-60}" t=0
    while ! pct status "$vmid" 2>/dev/null | grep -q running; do
        [ "$t" -ge "$limit" ] && return 1
        sleep 2; t=$((t + 2))
    done
}

# Before starting a service, wait for its depends_on conditions.
# Uses SVC_VMID (name -> vmid) and SVC_OPTS (name -> options JSON).
_wait_for_deps() {
    local name="$1" dep cond rc=0
    while IFS=$'\t' read -r dep cond; do
        [ -z "$dep" ] && continue
        case "$cond" in
            service_healthy)
                _wait_healthy "$dep" "${SVC_VMID[$dep]}" "${SVC_OPTS[$dep]}" || rc=1 ;;
            service_completed_successfully)
                echo "Waiting for $dep to finish..."
                local t=0
                while pct status "${SVC_VMID[$dep]}" | grep -q running && [ $t -lt 600 ]; do sleep 3; t=$((t + 3)); done ;;
            *)
                _wait_running "${SVC_VMID[$dep]}" 60 || { echo "Warning: $dep is not running"; rc=1; } ;;
        esac
    done < <(python3 -c 'import json, sys
for d, c in (json.loads(sys.argv[1] or "{}").get("depends_on") or {}).items():
    print(f"{d}\t{c}")' "${SVC_OPTS[$name]}")
    return $rc
}

# PVE boot order for a service: position in dependency order; services
# others wait on get an `up` delay (their healthcheck start period or 30s).
_startup_value() {
    local name="$1" position="$2"
    python3 - "$name" "$position" "${SVC_OPTS_ALL}" <<'EOF'
import json, sys
name, position, all_opts = sys.argv[1], int(sys.argv[2]), json.loads(sys.argv[3] or "{}")
needed = any(name in (o.get("depends_on") or {}) for o in all_opts.values())
up = ""
if needed:
    h = all_opts.get(name, {}).get("healthcheck") or {}
    up = f",up={max(30, int(h.get('start_period', 0)))}"
print(f"order={position}{up}")
EOF
}

# Plan a VMID and address for every service in SERVICES.
# Explicit per-service `x-pmxc: {vmid, ip}` must be free; otherwise VMIDs count
# up from START_VMID and addresses from NET_CIDR, skipping VMIDs in use.
# Prints "PLAN<TAB>name<TAB>vmid<TAB>ip/cidr ("-" for dhcp)<TAB>alias ("-" for
# none)" or "ERROR<TAB>message". Empty fields are "-" because bash's read
# treats tab as whitespace and would collapse them.
_plan_services() {
    local used_ids used_ips
    used_ids=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)
    used_ips=$(grep -h -o -E 'ip=[0-9.]+' /etc/pve/lxc/*.conf /etc/pve/nodes/*/lxc/*.conf 2>/dev/null; \
               grep -h -o -E 'ip=[0-9.]+' /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null)
    printf '%s\n' "${SERVICES[@]}" > "$TMP_DIR/services.tsv"
    python3 - "$START_VMID" "$IP_CONFIG" "$NET_CIDR" "$used_ids" "$used_ips" "$TMP_DIR/services.tsv" <<'EOF'
import ipaddress, json, sys
start, mode, cidr, ids_json, ips_raw, services_file = sys.argv[1:7]
used_ids = {int(r["vmid"]) for r in json.loads(ids_json or "[]") if "vmid" in r}
used_ips = {l.split("=", 1)[1] for l in ips_raw.split() if "=" in l}

def err(msg):
    print(f"ERROR\t{msg}")
    sys.exit(0)

services = []
for line in open(services_file).read().splitlines():
    if not line.strip():
        continue
    name, _image, _env, _vols, opts = line.split("\t")
    services.append((name, json.loads(opts)))

net = None
if mode == "static":
    try:
        first = ipaddress.ip_interface(cidr)
    except ValueError:
        err(f"invalid address '{cidr}' (expected e.g. 192.168.1.10/24)")
    net, next_ip = first.network, first.ip

next_id = int(start)
planned_ids, planned_ips = set(), set()
for name, o in services:
    if o.get("vmid"):
        vmid = int(o["vmid"])
        if vmid in used_ids or vmid in planned_ids:
            err(f"VMID {vmid} requested for service {name} is already in use")
    else:
        while next_id in used_ids or next_id in planned_ids:
            next_id += 1
        vmid = next_id
    planned_ids.add(vmid)

    ip = ""
    if mode == "static":
        if o.get("ip"):
            want = str(o["ip"])
            iface = ipaddress.ip_interface(want if "/" in want else f"{want}/{net.prefixlen}")
        else:
            while str(next_ip) in planned_ips:
                next_ip += 1
            iface = ipaddress.ip_interface(f"{next_ip}/{net.prefixlen}")
            next_ip += 1
        if iface.ip not in iface.network or iface.ip in (iface.network.network_address, iface.network.broadcast_address):
            err(f"address {iface} for service {name} is not a usable host address")
        if str(iface.ip) in used_ips or str(iface.ip) in planned_ips:
            err(f"address {iface.ip} for service {name} is already used by another guest")
        planned_ips.add(str(iface.ip))
        ip = str(iface)
    print(f"PLAN\t{name}\t{vmid}\t{ip or '-'}\t{o.get('container_name') or '-'}")
EOF
}

# Project hosts file: every service (and its container_name) by address.
_write_hosts_file() {
    echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
    local n
    for n in "${!SVC_IP[@]}"; do
        [ -n "${SVC_IP[$n]}" ] || continue
        echo "${SVC_IP[$n]%/*} $n${SVC_ALIAS[$n]:+ ${SVC_ALIAS[$n]}}"
    done | sort -V
}

# net0 address options for a planned service address ("" = DHCP).
_net_ip_opts() {
    if [ -n "$1" ]; then
        echo "ip=$1${NET_GW:+,gw=$NET_GW}"
    else
        echo "ip=dhcp"
    fi
}

# --- Core Logic ---

install_project() {
    created_vmids=()
    SVC_POSITION=0
    TARGET_NODE="" TEMPLATE_STORAGE="" ROOTFS_STORAGE="" VOL_STORAGE="" VOL_SIZE=""
    NET_BRIDGE="" NET_TAG="" IP_CONFIG="" NET_CIDR="" NET_GW="" START_VMID="" DATA_DIR=""
    # 1. Project Ingestion
    _ingest_project "$1" || return 1
    # COMPOSE_FILE and PROJECT_NAME are now set. METADATA_FILE is set.
    # (Updates of existing projects go through update_project, not here.)

    # Project-level defaults from the compose file's top-level x-pmxc block
    eval "$(_project_defaults_shell)"

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
            _require_setting node || return 1
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
             _require_setting template_storage || return 1
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
             _require_setting rootfs_storage || return 1
             ROOTFS_STORAGE=$(tui_menu "Select Container Storage (rootdir)" 15 60 4 "${OPTS[@]}")
             if [ -z "$ROOTFS_STORAGE" ]; then return; fi
        fi
    else
        echo "Using Configured Container Storage: $ROOTFS_STORAGE"
    fi

    # Volume Storage (Virtual Disks)
    if [ -z "$VOL_STORAGE" ] && [ "$ASSUME_YES" = "true" ]; then VOL_STORAGE="$ROOTFS_STORAGE"; fi
    if [ -z "$VOL_SIZE" ] && [ "$ASSUME_YES" = "true" ]; then VOL_SIZE="16G"; fi
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
             _require_setting bridge || return 1
             NET_BRIDGE=$(tui_menu "Select Network Bridge" 15 60 4 "${BRIDGE_MENU_OPTIONS[@]}")
             if [ -z "$NET_BRIDGE" ]; then return; fi
        else
            if ! tui_input "No bridges detected. Enter bridge name:" "vmbr0" NET_BRIDGE; then return; fi
        fi
        NET_BRIDGE=${NET_BRIDGE:-vmbr0}
    else
        echo "Using Configured Bridge: $NET_BRIDGE"
    fi

    # VLAN tag (optional)
    if [ -z "$NET_TAG" ] && [ "$ASSUME_YES" != "true" ]; then
        tui_input "VLAN tag (leave empty for none):" "" NET_TAG || return 1
    fi

    # Network Configuration (DHCP vs Static)
    if [ -z "$IP_CONFIG" ]; then
         _require_setting ip || return 1
         IP_CONFIG=$(tui_menu "IP Configuration" 10 60 2 "dhcp" "Auto (DHCP)" "static" "Static IP")
         if [ -z "$IP_CONFIG" ]; then return; fi
        
        if [ "$IP_CONFIG" = "static" ]; then
            if ! tui_input "IPv4/CIDR of the first service (e.g. 192.168.1.10/24).\nFurther services get the following addresses:" "" NET_CIDR; then return; fi
            if ! tui_input "Gateway (e.g. 192.168.1.1):" "" NET_GW; then return; fi
        fi
    fi
    
    DATA_DIR="${DATA_DIR:-$PROJECT_DIR/volumes}"

    # Save Config
    _save_project_config

    # Starting VMID
    if [ -z "$START_VMID" ]; then
        DEFAULT_VMID=$(get_next_vmid)
        if [ "$ASSUME_YES" = "true" ]; then
            START_VMID="$DEFAULT_VMID"
        else
            if ! tui_input "Starting VMID:" "$DEFAULT_VMID" START_VMID; then return; fi
            START_VMID=${START_VMID:-$DEFAULT_VMID}
        fi
    fi


# 3. Parse Compose File
echo "Parsing $COMPOSE_FILE..."
while ! load_services; do
    # Usually a missing ${VAR} for a URL-sourced compose file: let the user fill in .env
    if [ -t 0 ] && tui_yesno "The compose file could not be resolved (see the terminal output, e.g. a required variable is missing).\n\nEdit $PROJECT_DIR/.env now and retry?"; then
        nano "$PROJECT_DIR/.env"
    else
        tui_msg "Error: The compose file could not be resolved. Nothing was deployed."
        return 1
    fi
done

# Dependency order (depends_on); services are created and started in it
local ordered
if ! ordered=$(_service_order); then
    tui_msg "Error: invalid depends_on (see above)."
    return 1
fi
declare -A SVC_OPTS
local svc_line
for svc_line in "${SERVICES[@]}"; do
    SVC_OPTS["${svc_line%%$'\t'*}"]="${svc_line##*$'\t'}"
done
SVC_OPTS_ALL=$(for k in "${!SVC_OPTS[@]}"; do printf '%s\t%s\n' "$k" "${SVC_OPTS[$k]}"; done | python3 -c 'import json, sys
print(json.dumps({l.split("\t", 1)[0]: json.loads(l.split("\t", 1)[1]) for l in sys.stdin.read().splitlines() if l}))')
local -a ORDERED_SERVICES=()
local o_name
while read -r o_name; do
    for svc_line in "${SERVICES[@]}"; do
        [ "${svc_line%%$'\t'*}" = "$o_name" ] && ORDERED_SERVICES+=("$svc_line")
    done
done <<< "$ordered"
SERVICES=("${ORDERED_SERVICES[@]}")

# Per-service VMID and address, checked against existing containers
declare -A SVC_VMID SVC_IP SVC_ALIAS
local plan_line p_name p_vmid p_ip p_alias
while IFS=$'\t' read -r plan_line p_name p_vmid p_ip p_alias; do
    case "$plan_line" in
        ERROR) tui_msg "Error: $p_name"; return 1 ;;
        PLAN)
            [ "$p_ip" = "-" ] && p_ip=""
            [ "$p_alias" = "-" ] && p_alias=""
            SVC_VMID["$p_name"]="$p_vmid"; SVC_IP["$p_name"]="$p_ip"; SVC_ALIAS["$p_name"]="$p_alias"
            echo "Planned: $p_name -> VMID $p_vmid, ${p_ip:-dhcp}" ;;
    esac
done < <(_plan_services)
if [ ${#SVC_VMID[@]} -ne ${#SERVICES[@]} ]; then
    tui_msg "Error: Could not plan VMIDs/addresses for all services."
    return 1
fi

# Volumes: decide bind / shared / PVE volume per service, before creating anything
declare -A SVC_VOLS SHARED_USERS
NEW_SHARED_DIRS=()
local v_kind v_svc v_a v_b v_c v_d v_e
while IFS=$'\t' read -r v_kind v_svc v_a v_b v_c v_d v_e; do
    case "$v_kind" in
        ERROR) tui_msg "Error: $v_svc"; return 1 ;;
        SKIP) echo "Note: skipping volume $v_a of $v_svc: $v_b" ;;
        VOL)
            SVC_VOLS["$v_svc"]+="$v_a"$'\t'"$v_b"$'\t'"$v_c"$'\t'"$v_d"$'\t'"$v_e"$'\n'
            if [ "$v_a" = "shared" ]; then
                case " ${SHARED_USERS[$v_d]} " in *" $v_svc "*) ;; *) SHARED_USERS["$v_d"]+="$v_svc " ;; esac
            fi ;;
    esac
done < <(_plan_volumes)
for d in "${!SHARED_USERS[@]}"; do
    if [ ! -e "$d" ]; then
        mkdir -p "$d" && NEW_SHARED_DIRS+=("$d")
    fi
    _check_traversable "$(dirname "$d")" || return 1
done

HOSTS_FILE=""
if [ "$IP_CONFIG" = "static" ]; then
    HOSTS_FILE="$PROJECT_DIR/hosts"
    _write_hosts_file > "$HOSTS_FILE"
    chmod 644 "$HOSTS_FILE"
    _check_traversable "$PROJECT_DIR" || return 1
elif [ ${#SERVICES[@]} -gt 1 ]; then
    echo "Note: with DHCP, services can't reach each other by name (no hosts file). Use static addresses for multi-service projects."
fi

# Metadata collection Array
METADATA_SERVICES_JSON="[]"

for SERVICE_LINE in "${SERVICES[@]}"; do
    IFS=$'\t' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON S_OPTS_JSON <<< "$SERVICE_LINE"
    
    echo ""
    echo "--- Deploying Service: $S_NAME ---"
    echo "Image: $S_IMAGE"
    CURRENT_VMID="${SVC_VMID[$S_NAME]}"
    echo "Target VMID: $CURRENT_VMID"
    
    # Metadata for this service
    SERVICE_VOLUMES_LOG="[]"

    # --- 2. Pull Image (sets TEMPLATE_VOLID) ---
    _pull_image "$S_IMAGE" || exit 1

    # --- 4. Create Container (RootFS Only) ---
    echo "Creating container $CURRENT_VMID..."
    
    # Sanitize size (strip G/GB) for ZFS compatibility
    CLEAN_VOL_SIZE=$(echo "$VOL_SIZE" | tr -cd '0-9')
    # Resources from the compose file (mem_limit/cpus/deploy limits/x-pmxc)
    eval "$(_opts_shell "$S_OPTS_JSON")"
    
    pct create $CURRENT_VMID "$TEMPLATE_VOLID" \
        --hostname "$S_NAME" \
        --cores "${OPT_CORES:-1}" \
        --memory "${OPT_MEMORY:-512}" \
        --swap "${OPT_SWAP:-512}" \
        --onboot "${OPT_ONBOOT:-0}" \
        --net0 "name=eth0,bridge=$NET_BRIDGE,firewall=1${NET_TAG:+,tag=$NET_TAG},$(_net_ip_opts "${SVC_IP[$S_NAME]}")" \
        --rootfs "$ROOTFS_STORAGE:${OPT_ROOTFS_SIZE:-$CLEAN_VOL_SIZE}" \
        --features nesting=1 \
        --unprivileged 1 \
        --start 0 || { echo "Error: Failed to create container $CURRENT_VMID"; exit 1; }
    
    VMID_FOR_TRACKING=$CURRENT_VMID

    # --- 5. Volumes (planned above) ---
    echo "Processing volumes..."
    MP_INDEX=0
    while IFS=$'\t' read -r V_KIND V_SOURCE V_TARGET V_HOST V_RO; do
        [ -z "$V_KIND" ] && continue
        [ "$V_HOST" = "-" ] && V_HOST=""
        echo "  $V_SOURCE -> $V_TARGET ($V_KIND${V_HOST:+: $V_HOST})"
        if ! PROXMOX_VOLID=$(_attach_volume "$CURRENT_VMID" "$MP_INDEX" "$V_KIND" "$V_TARGET" "$V_HOST" "$V_RO"); then
            echo "Error: Failed to attach volume $V_SOURCE to $CURRENT_VMID"
            exit 1
        fi
        if [ "$V_KIND" = "volume" ]; then
            SERVICE_VOLUMES_LOG=$(python3 -c 'import json, sys; l = json.loads(sys.argv[1]); l.append({"source": sys.argv[2], "volid": sys.argv[3], "mp": sys.argv[4], "type": "volume"}); print(json.dumps(l))' \
                "$SERVICE_VOLUMES_LOG" "$V_SOURCE" "$PROXMOX_VOLID" "$V_TARGET")
        fi
        MP_INDEX=$((MP_INDEX + 1))
    done <<< "${SVC_VOLS[$S_NAME]}"

    # Service-name resolution: bind the project hosts file over /etc/hosts
    if [ -n "$HOSTS_FILE" ]; then
        echo "lxc.mount.entry: $HOSTS_FILE etc/hosts none bind,ro,create=file 0 0" >> "/etc/pve/lxc/${CURRENT_VMID}.conf"
    fi

    # --- 6. Environment (image defaults + compose) ---
    echo "Setting environment variables..."
    _apply_runtime "$CURRENT_VMID" "" "" "$(_template_path "$TEMPLATE_VOLID")" "$S_ENV_JSON" "$S_OPTS_JSON" | sed -n 's/^\(SET\|WARN\|NOTE\)\t/  /p'
    echo "Environment variables set."

    # Boot order (PVE startup) follows the dependency order
    SVC_POSITION=$(( ${SVC_POSITION:-0} + 1 ))
    pct set "$CURRENT_VMID" --startup "$(_startup_value "$S_NAME" "$SVC_POSITION")" >/dev/null

    # --- 7. Start (after its dependencies are up / healthy) ---
    _wait_for_deps "$S_NAME" || echo "Warning: starting $S_NAME although a dependency is not ready"
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
    'template': '$TEMPLATE_VOLID',
    'ip': '${SVC_IP[$S_NAME]}',
    'volumes': json.loads('$SERVICE_VOLUMES_LOG')
})
print(json.dumps(services))
")

    created_vmids+=("$VMID_FOR_TRACKING")
done

    _own_shared_dirs

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
            if not key.startswith(image_lxc):
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
    local name="$1" vmid="$2" image="$3" env_json="$4" vols_json="$5" old_template="$6" opts_json="$7"
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
    local -a keep_keys=() keep_vals=() data_keys=() data_targets=() bind_keys=() bind_vals=() raw_lines=()
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
        esac
    done < <(_describe_container "$vmid")
    rootfs_storage="${rootfs_storage:-$ROOTFS_STORAGE}"
    rootfs_size="${rootfs_size:-8}"
    # Compose resources (mem_limit/cpus/deploy limits/x-pmxc) override the
    # container's current values; unset ones keep what the container has.
    eval "$(_opts_shell "$opts_json")"
    if [ -n "$OPT_ROOTFS_SIZE" ] && [ "$OPT_ROOTFS_SIZE" -gt "$rootfs_size" ]; then rootfs_size="$OPT_ROOTFS_SIZE"; fi

    local backup="$PROJECT_DIR/${vmid}-$(date +%Y%m%d-%H%M%S).conf.bak"
    cp "$conf" "$backup"
    echo "Saved current config to $backup"

    # 2. Pull the new image and prove it can be turned into a container
    # The template this container was built from tells us which runtime
    # settings are image defaults and which are customisations. Older
    # metadata doesn't record it; fall back to the newest template for the image.
    if [ -z "$(_template_path "$old_template")" ]; then
        old_template=$(_list_templates "$image" | LC_ALL=C sort | tail -n 1)
        [ -n "$old_template" ] && echo "Assuming $vmid was built from $old_template"
    fi
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
    local opt val
    for opt in cores memory swap onboot; do
        val="OPT_${opt^^}"
        [ -n "${!val}" ] && { pct set "$vmid" "--$opt" "${!val}" || echo "Warning: could not set $opt"; }
    done

    # 5. Bring the data back
    if ! _move_data_volumes "$stage" "$vmid" "${data_keys[@]}"; then
        echo "Error: Failed to move data volumes back to $vmid. Old config: $backup"
        return 1
    fi
    PARKED_VOLUMES_ON=""
    pct destroy "$stage" --purge >/dev/null 2>&1 || echo "Warning: could not remove staging container $stage"

    # Compose volumes whose mount point isn't provided yet (by a moved volume
    # or a bind mount) are added according to the volume plan
    local v_kind v_source v_target v_host v_ro n=0 volid
    while IFS=$'\t' read -r v_kind v_source v_target v_host v_ro; do
        [ -z "$v_kind" ] && continue
        [ "$v_host" = "-" ] && v_host=""
        if grep -q -E "^mp[0-9]+: [^,]+,(.*,)?mp=$v_target(,|$)" "$conf"; then
            continue
        fi
        if [ "$v_kind" = "missing" ]; then
            echo "Warning: $v_target is not mounted: host path $v_host does not exist"
            continue
        fi
        while grep -q "^mp$n:" "$conf"; do n=$((n + 1)); done
        if [ "$v_kind" = "shared" ] && [ ! -e "$v_host" ]; then
            mkdir -p "$v_host"
            local base uid gid
            base=$(sed -n -E 's/^lxc.idmap: u 0 ([0-9]+) .*/\1/p' "$conf" | head -n 1)
            uid=$(sed -n 's/^lxc.init.uid: //p' "$conf" | head -n 1)
            gid=$(sed -n 's/^lxc.init.gid: //p' "$conf" | head -n 1)
            chown "$(( ${base:-100000} + ${uid:-0} )):$(( ${base:-100000} + ${gid:-${uid:-0}} ))" "$v_host"
            chmod 2775 "$v_host"
        fi
        echo "Adding volume '$v_source' at $v_target ($v_kind${v_host:+: $v_host})"
        volid=$(_attach_volume "$vmid" "$n" "$v_kind" "$v_target" "$v_host" "$v_ro") || echo "Warning: could not add volume for $v_target"
    done <<< "${SVC_VOLS[$name]}"

    # 6. Runtime settings: new image defaults, previous customisations
    #    (entrypoint, env, init user/cwd) and the compose environment
    if [ ${#raw_lines[@]} -gt 0 ]; then
        local tmp_conf="$TMP_DIR/$vmid.conf"
        { printf '%s\n' "${raw_lines[@]}" | grep '^#'; grep -v '^#' "$conf"; printf '%s\n' "${raw_lines[@]}" | grep -v '^#'; } > "$tmp_conf"
        cat "$tmp_conf" > "$conf"
    fi
    local kind msg
    while IFS=$'\t' read -r kind msg; do
        case "$kind" in
            KEPT) echo "Kept $msg" ;;
            SET) echo "Set $msg" ;;
            NOTE) echo "Note: $msg" ;;
            WARN) echo "WARNING: $msg" ;;
        esac
    done < <(_apply_runtime "$vmid" "$backup" "$(_template_path "$old_template")" "$(_template_path "$TEMPLATE_VOLID")" "$env_json" "$opts_json")

    if [ "$(python3 -c 'import json, sys; print(bool((json.loads(sys.argv[1] or "{}").get("depends_on")) or any(sys.argv[2] in (o.get("depends_on") or {}) for o in json.loads(sys.argv[3] or "{}").values())))' "$opts_json" "$name" "$SVC_OPTS_ALL")" = "True" ]; then
        pct set "$vmid" --startup "$(_startup_value "$name" "$UPDATE_POSITION")" >/dev/null
    fi

    if [ "$was_running" = "true" ]; then
        _wait_for_deps "$name" || echo "Warning: starting $name although a dependency is not ready"
        echo "Starting container $vmid..."
        pct start "$vmid" || echo "Warning: Container $vmid failed to start."
    fi

    _prune_templates "$image" "$TEMPLATE_VOLID" "$old_template"
    UPDATED_TEMPLATE="$TEMPLATE_VOLID"
    echo "Service $name updated."
}

# Record which template a service's container was built from.
_set_service_template() {
    python3 - "$METADATA_FILE" "$1" "$2" <<'EOF2'
import json, sys
path, name, template = sys.argv[1:4]
with open(path) as f:
    meta = json.load(f)
for s in meta.get("services", []):
    if s.get("name") == name:
        s["template"] = template
with open(path, "w") as f:
    json.dump(meta, f, indent=2)
EOF2
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
    local -A vmid_of=() template_of=()
    local s_name s_vmid s_tmpl
    while IFS=$'\t' read -r s_name s_vmid s_tmpl; do
        vmid_of["$s_name"]="$s_vmid"
        template_of["$s_name"]="$s_tmpl"
    done < <(python3 -c 'import json, sys
for s in json.load(open(sys.argv[1])).get("services", []):
    print(str(s.get("name")) + "\t" + str(s.get("vmid")) + "\t" + str(s.get("template") or ""))' "$METADATA_FILE")

    if ! load_services; then
        _notify "Error: The compose file could not be resolved. Nothing was changed."
        return 1
    fi
    if [ ${#SERVICES[@]} -eq 0 ]; then
        _notify "Error: No services found in $COMPOSE_FILE."
        return 1
    fi

    # Dependency order, and name -> vmid / options for dependency waits
    local ordered
    if ! ordered=$(_service_order); then
        _notify "Error: invalid depends_on. Nothing was changed."
        return 1
    fi
    declare -A SVC_OPTS=() SVC_VMID=()
    local svc_line o_name
    for svc_line in "${SERVICES[@]}"; do
        SVC_OPTS["${svc_line%%$'\t'*}"]="${svc_line##*$'\t'}"
    done
    for o_name in "${!vmid_of[@]}"; do SVC_VMID["$o_name"]="${vmid_of[$o_name]}"; done
    SVC_OPTS_ALL=$(for o_name in "${!SVC_OPTS[@]}"; do printf '%s\t%s\n' "$o_name" "${SVC_OPTS[$o_name]}"; done | python3 -c 'import json, sys
print(json.dumps({l.split("\t", 1)[0]: json.loads(l.split("\t", 1)[1]) for l in sys.stdin.read().splitlines() if l}))')
    local -a ordered_services=()
    while read -r o_name; do
        for svc_line in "${SERVICES[@]}"; do
            [ "${svc_line%%$'\t'*}" = "$o_name" ] && ordered_services+=("$svc_line")
        done
    done <<< "$ordered"
    SERVICES=("${ordered_services[@]}")

    DATA_DIR="${DATA_DIR:-$PROJECT_DIR/volumes}"
    declare -A SVC_VOLS=()
    local v_kind v_svc v_a v_b v_c v_d v_e
    while IFS=$'\t' read -r v_kind v_svc v_a v_b v_c v_d v_e; do
        case "$v_kind" in
            ERROR) _notify "Error: $v_svc. Nothing was changed."; return 1 ;;
            VOL) SVC_VOLS["$v_svc"]+="$v_a"$'\t'"$v_b"$'\t'"$v_c"$'\t'"$v_d"$'\t'"$v_e"$'\n' ;;
        esac
    done < <(_plan_volumes update)

    local summary="" line S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON S_OPTS_JSON
    for line in "${SERVICES[@]}"; do
        IFS=$'\t' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON S_OPTS_JSON <<< "$line"
        summary="$summary\n- $S_NAME ($S_IMAGE) -> VMID ${vmid_of[$S_NAME]:-not deployed}"
    done
    if ! _confirm "Update '$p_name'?\n$summary\n\nEach container is rebuilt from a freshly pulled image under the same VMID. Data volumes are moved aside and back, never deleted."; then
        return 0
    fi

    # 4. Update each service (dependencies first)
    local failed=0
    UPDATE_POSITION=0
    for line in "${SERVICES[@]}"; do
        IFS=$'\t' read -r S_NAME S_IMAGE S_ENV_JSON S_VOLS_JSON S_OPTS_JSON <<< "$line"
        if [ -z "${vmid_of[$S_NAME]}" ]; then
            echo "Skipping '$S_NAME': not deployed yet (new service in the compose file)."
            continue
        fi
        UPDATED_TEMPLATE=""
        UPDATE_POSITION=$(( ${UPDATE_POSITION:-0} + 1 ))
        if update_service "$S_NAME" "${vmid_of[$S_NAME]}" "$S_IMAGE" "$S_ENV_JSON" "$S_VOLS_JSON" "${template_of[$S_NAME]}" "$S_OPTS_JSON"; then
            _set_service_template "$S_NAME" "$UPDATED_TEMPLATE"
        else
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
    echo "       $0 install <file|url> [-y] Install a project (-y: no prompts; settings from x-pmxc)"
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
    install)
        if [ -z "${2:-}" ]; then
            usage
            exit 1
        fi
        [ "${3:-}" = "-y" ] || [ "${3:-}" = "--yes" ] && ASSUME_YES="true"
        install_project "$2"
        exit $?
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
