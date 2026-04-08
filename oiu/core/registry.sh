#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# OIU — registry.sh
# Manages the OIU registry. Tracks every installed app: version, paths, manifest.
# Requires: system.sh sourced first (uses OIU_HOME, OIU_IS_ROOT)
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Registry path ────────────────────────────────────────────────────────────
# System install (sudo): /usr/local/share/oiu/registry.json
# User install:          ~/.local/share/oiu/registry.json
# The calling script sets OIU_INSTALL_TYPE before sourcing registry.sh,
# or we default to user-level.
_oiu_registry_path() {
    if [[ "${OIU_SCOPE:-user}" == "system" ]]; then
        echo "/usr/local/share/oiu/registry.json"
    else
        echo "${OIU_HOME}/.local/share/oiu/registry.json"
    fi
}

OIU_REGISTRY="${OIU_REGISTRY:-$(_oiu_registry_path)}"

# ─── Ensure registry exists ──────────────────────────────────────────────────
oiu_registry_init() {
    local reg_dir
    reg_dir="$(dirname "$OIU_REGISTRY")"

    if [[ ! -d "$reg_dir" ]]; then
        mkdir -p "$reg_dir" 2>/dev/null || {
            [[ -n "${OIU_SUDO}" && "${OIU_SUDO}" != "none" ]] && \
                $OIU_SUDO mkdir -p "$reg_dir"
        }
    fi

    if [[ ! -f "$OIU_REGISTRY" ]]; then
        local init_json
        init_json=$(printf '{\n  "oiu_version": "%s",\n  "apps": {}\n}\n' "${OIU_VERSION:-1.0.0}")
        echo "$init_json" > "$OIU_REGISTRY" 2>/dev/null || \
            echo "$init_json" | $OIU_SUDO tee "$OIU_REGISTRY" >/dev/null
    fi
}

# ─── Check if app is registered ──────────────────────────────────────────────
# Usage: oiu_registry_has "appname"
# Returns 0 (true) if registered, 1 if not
oiu_registry_has() {
    local app="$1"
    [[ -f "$OIU_REGISTRY" ]] || return 1
    OIU_REG_PATH="$OIU_REGISTRY" OIU_REG_APP="$app" \
    python3 - <<'PYEOF' 2>/dev/null
import json, sys, os
try:
    r = json.load(open(os.environ['OIU_REG_PATH']))
    sys.exit(0 if os.environ['OIU_REG_APP'] in r.get('apps', {}) else 1)
except Exception:
    sys.exit(1)
PYEOF
}

# ─── Get a field from a registered app ───────────────────────────────────────
# Usage: oiu_registry_get "appname" "field"
# e.g.   oiu_registry_get ytcui version
oiu_registry_get() {
    local app="$1" field="$2"
    [[ -f "$OIU_REGISTRY" ]] || return 1
    OIU_REG_PATH="$OIU_REGISTRY" OIU_REG_APP="$app" OIU_REG_FIELD="$field" \
    python3 - <<'PYEOF' 2>/dev/null
import json, sys, os
try:
    r = json.load(open(os.environ['OIU_REG_PATH']))
    val = r['apps'][os.environ['OIU_REG_APP']][os.environ['OIU_REG_FIELD']]
    print(val if isinstance(val, str) else json.dumps(val))
except Exception:
    sys.exit(1)
PYEOF
}

# ─── Register or update an app entry ─────────────────────────────────────────
# Usage: oiu_registry_write "appname" key=value key=value ...
# Special key: manifest= takes a newline-separated list of paths
# Example:
#   oiu_registry_write myapp \
#       version="2.8.0" \
#       binary_path="/usr/local/bin/myapp" \
#       install_scope="system" \
#       update_url="https://..." \
#       update_mode="notify" \
#       github_repo="user/repo" \
#       uninstaller="/usr/local/share/oiu/uninstallers/myapp.sh" \
#       manifest="/usr/local/bin/myapp
#/usr/local/share/myapp
#/usr/share/applications/myapp.desktop"
oiu_registry_write() {
    local app="$1"; shift
    oiu_registry_init

    # Build a Python dict from key=value pairs passed as args
    local py_kwargs=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        # Escape for Python string
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        py_kwargs+="    fields['$key'] = \"\"\"$val\"\"\"\n"
    done

    # Write fields to a temp JSON file to avoid shell escaping nightmares
    local tmp_fields
    tmp_fields=$(mktemp)
    python3 -c "import json; print(json.dumps({}))" > "$tmp_fields"

    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        python3 - "$tmp_fields" "$key" <<PYEOF
import json, sys
path, key = sys.argv[1], sys.argv[2]
val = """$val"""
with open(path, 'r') as f: d = json.load(f)
d[key] = val
with open(path, 'w') as f: json.dump(d, f)
PYEOF
    done

    python3 - "$tmp_fields" <<PYEOF
import json, sys
from datetime import datetime, timezone

fields_path = sys.argv[1]
reg_path    = '$OIU_REGISTRY'
app         = '$app'

with open(fields_path, 'r') as f:
    fields = json.load(f)

try:
    with open(reg_path, 'r') as f:
        reg = json.load(f)
except Exception:
    reg = {"oiu_version": "${OIU_VERSION:-1.0.0}", "apps": {}}

if 'manifest' in fields:
    raw = fields['manifest']
    if isinstance(raw, str):
        fields['manifest'] = [l.strip() for l in raw.strip().split('\n') if l.strip()]

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
if app not in reg['apps']:
    reg['apps'][app] = {'installed_at': now}

reg['apps'][app].update(fields)
reg['apps'][app]['updated_at'] = now

with open(reg_path, 'w') as f:
    json.dump(reg, f, indent=2)
    f.write('\n')
PYEOF
    rm -f "$tmp_fields"
}

# ─── Remove an app from the registry ─────────────────────────────────────────
# Usage: oiu_registry_remove "appname"
oiu_registry_remove() {
    local app="$1"
    [[ -f "$OIU_REGISTRY" ]] || return 0
    python3 - <<PYEOF
import json, sys
try:
    with open('$OIU_REGISTRY', 'r') as f:
        reg = json.load(f)
    reg['apps'].pop('$app', None)
    with open('$OIU_REGISTRY', 'w') as f:
        json.dump(reg, f, indent=2)
        f.write('\n')
except Exception as e:
    print(f'Registry remove error: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ─── List all registered apps ─────────────────────────────────────────────────
# Usage: oiu_registry_list
# Prints: appname version install_scope  (tab-separated)
oiu_registry_list() {
    [[ -f "$OIU_REGISTRY" ]] || return 0
    python3 - <<PYEOF
import json, sys
try:
    with open('$OIU_REGISTRY', 'r') as f:
        reg = json.load(f)
    apps = reg.get('apps', {})
    if not apps:
        print("  (no apps registered)")
    for name, info in apps.items():
        ver    = info.get('version', '?')
        scope  = info.get('install_scope', 'user')
        binary = info.get('binary_path', '?')
        date   = info.get('installed_at', '?')[:10]
        print(f"  {name:<20} {ver:<12} {scope:<8} {binary:<35} {date}")
except Exception as e:
    print(f'Registry read error: {e}', file=sys.stderr)
PYEOF
}

# ─── Get manifest for an app ──────────────────────────────────────────────────
# Usage: oiu_registry_manifest "appname"
# Prints one file/dir path per line
oiu_registry_manifest() {
    local app="$1"
    [[ -f "$OIU_REGISTRY" ]] || return 1
    python3 - <<PYEOF
import json, sys
try:
    with open('$OIU_REGISTRY', 'r') as f:
        reg = json.load(f)
    for path in reg['apps']['$app'].get('manifest', []):
        print(path)
except: sys.exit(1)
PYEOF
}

export OIU_REGISTRY
export -f oiu_registry_init oiu_registry_has oiu_registry_get
export -f oiu_registry_write oiu_registry_remove
export -f oiu_registry_list oiu_registry_manifest
