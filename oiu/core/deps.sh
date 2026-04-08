#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# OIU — deps.sh
# Installs dependencies declared in oiu.conf [deps] section.
# Requires: system.sh sourced first. OIU_CONF_FILE set to oiu.conf path.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Privilege escalation helper ────────────────────────────────────────────
_oiu_priv() {
    if [[ "$OIU_IS_ROOT" == "yes" ]]; then
        "$@"
    elif [[ "$OIU_SUDO" == "sudo" ]]; then
        sudo "$@"
    elif [[ "$OIU_SUDO" == "doas" ]]; then
        doas "$@"
    else
        echo "  [!] No privilege escalation available. Run as root or install sudo/doas." >&2
        return 1
    fi
}

# ─── Package manager: update index ───────────────────────────────────────────
_oiu_pm_update() {
    case "$OIU_PKG_MANAGER" in
        apt)     _oiu_priv apt-get update -qq 2>/dev/null || true ;;
        pacman)  _oiu_priv pacman -Sy --noconfirm 2>/dev/null || true ;;
        dnf)     _oiu_priv dnf check-update -q 2>/dev/null || true ;;
        yum)     _oiu_priv yum check-update -q 2>/dev/null || true ;;
        zypper)  _oiu_priv zypper refresh -q 2>/dev/null || true ;;
        apk)     _oiu_priv apk update -q 2>/dev/null || true ;;
        brew)    brew update 2>/dev/null || true ;;
        pkg)     _oiu_priv pkg update 2>/dev/null || true ;;
        pkgin)   _oiu_priv pkgin update 2>/dev/null || true ;;
        *)       true ;;
    esac
}

# ─── Package manager: install one package ─────────────────────────────────────
# Usage: _oiu_pm_install "pkg-name"
_oiu_pm_install() {
    local pkg="$1"
    case "$OIU_PKG_MANAGER" in
        apt)      _oiu_priv apt-get install -y "$pkg" ;;
        pacman)   _oiu_priv pacman -S --noconfirm "$pkg" ;;
        dnf)      _oiu_priv dnf install -y "$pkg" ;;
        yum)      _oiu_priv yum install -y "$pkg" ;;
        zypper)   _oiu_priv zypper install -y "$pkg" ;;
        apk)      _oiu_priv apk add --no-cache "$pkg" ;;
        emerge)   _oiu_priv emerge "$pkg" ;;
        xbps)     _oiu_priv xbps-install -y "$pkg" ;;
        brew)     brew install "$pkg" ;;
        macports) _oiu_priv port install "$pkg" ;;
        pkg)      _oiu_priv pkg install -y "$pkg" ;;
        pkg_add)  _oiu_priv pkg_add "$pkg" ;;
        pkgin)    _oiu_priv pkgin -y install "$pkg" ;;
        *)
            echo "  [!] Unknown package manager '$OIU_PKG_MANAGER'. Install '$pkg' manually." >&2
            return 1
            ;;
    esac
}

# ─── Check if a command/package is already installed ─────────────────────────
# Usage: _oiu_pkg_installed "command-name"
_oiu_pkg_installed() {
    command -v "$1" &>/dev/null
}

# ─── Parse deps from oiu.conf and install ─────────────────────────────────────
# oiu.conf [deps] format:
#   logical_name.pkg_manager = package-name
#   logical_name.optional    = true
#   logical_name.command     = command-to-check-if-installed
#   logical_name.description = Human readable description
#
# Example:
#   ncurses.apt     = libncursesw5-dev
#   ncurses.pacman  = ncurses
#   ncurses.brew    = ncurses
#   ncurses.command = ncurses-config   (optional: what command means "installed")
#   ncurses.optional = false
#   mpv.apt         = mpv
#   mpv.command     = mpv
#   chafa.optional  = true
#   chafa.description = Terminal image preview (thumbnails)

oiu_deps_install() {
    local conf="${OIU_CONF_FILE:-oiu.conf}"
    [[ -f "$conf" ]] || { echo "  [!] oiu.conf not found at: $conf" >&2; return 1; }

    local pm="$OIU_PKG_MANAGER"

    # Parse deps section via python
    local deps_json
    deps_json=$(OIU_CONF_PATH="$conf" python3 - <<'PYEOF'
import sys, os, re

conf_path = os.environ['OIU_CONF_PATH']
in_deps = False
in_optional = False
deps = {}   # logical_name -> {pm: pkgname, optional: bool, command: str, description: str}

with open(conf_path) as f:
    for line in f:
        line = line.rstrip()
        stripped = line.strip()

        # Section headers
        if stripped.startswith('[deps.optional]'):
            in_deps = True; in_optional = True; continue
        elif stripped.startswith('[deps]'):
            in_deps = True; in_optional = False; continue
        elif stripped.startswith('[') and stripped.endswith(']'):
            in_deps = False; in_optional = False; continue

        if not in_deps:
            continue
        if not stripped or stripped.startswith('#'):
            continue

        m = re.match(r'^(\w[\w-]*)\.(\w[\w-]*)\s*=\s*(.+)$', stripped)
        if not m:
            continue
        logical, key, val = m.group(1), m.group(2), m.group(3).strip()

        if logical not in deps:
            deps[logical] = {'optional': False, 'command': '', 'description': '', 'pms': {}}

        if key == 'optional':
            deps[logical]['optional'] = val.lower() in ('true', 'yes', '1')
        elif key == 'command':
            deps[logical]['command'] = val
        elif key == 'description':
            deps[logical]['description'] = val
        else:
            # key is a package manager name
            deps[logical]['pms'][key] = val

        if in_optional:
            deps[logical]['optional'] = True

import json
print(json.dumps(deps))
PYEOF
) || return 1

    # Install each dep
    local any_updated=0
    OIU_DEPS_JSON="$deps_json" OIU_PM="$pm" python3 - <<'PYEOF'
import json, os, subprocess, sys

deps = json.loads(os.environ['OIU_DEPS_JSON'])
pm   = os.environ['OIU_PM']

for logical, info in deps.items():
    pkg         = info['pms'].get(pm, '')
    optional    = info.get('optional', False)
    check_cmd   = info.get('command', logical)  # default: check if logical name is a command
    description = info.get('description', '')

    label = f"  {'(optional) ' if optional else ''}{logical}"
    if description:
        label += f" — {description}"

    # Check if already installed
    result = subprocess.run(['command', '-v', check_cmd or logical],
                            shell=False, capture_output=True, executable='/bin/bash',
                            env={**os.environ, 'PATH': os.environ.get('PATH','/usr/bin:/bin')})
    if result.returncode == 0:
        print(f"  \033[32m✓\033[0m {logical:<20} already installed")
        continue

    if not pkg:
        if optional:
            print(f"  \033[2m○\033[0m {logical:<20} no package for '{pm}' — skipping (optional)")
        else:
            print(f"  \033[33m!\033[0m {logical:<20} no package defined for '{pm}' — install manually", file=sys.stderr)
        continue

    print(f"  \033[36m→\033[0m {logical:<20} installing {pkg}...", flush=True)
PYEOF

    # Actually run installs (python can't easily call _oiu_pm_install with priv)
    # Re-parse and install via bash
    OIU_DEPS_JSON="$deps_json" OIU_PM="$pm" \
    python3 -c "
import json, os, sys
deps = json.loads(os.environ['OIU_DEPS_JSON'])
pm   = os.environ['OIU_PM']
for logical, info in deps.items():
    pkg = info['pms'].get(pm, '')
    optional = info.get('optional', False)
    check = info.get('command', logical)
    if pkg:
        print(f'{logical}|{pkg}|{\"optional\" if optional else \"required\"}|{check}')
" | while IFS='|' read -r logical pkg req check_cmd; do
        # Check if already installed
        if command -v "${check_cmd:-$logical}" &>/dev/null; then
            echo "  $(printf '\033[32m')✓$(printf '\033[0m') ${logical} (already installed)"
            continue
        fi

        echo "  $(printf '\033[36m')→$(printf '\033[0m') Installing ${logical} (${pkg})..."
        if _oiu_pm_install "$pkg"; then
            echo "  $(printf '\033[32m')✓$(printf '\033[0m') ${logical}"
        else
            if [[ "$req" == "optional" ]]; then
                echo "  $(printf '\033[33m')○$(printf '\033[0m') ${logical} (optional — skipped, feature disabled)"
            else
                echo "  $(printf '\033[31m')✗$(printf '\033[0m') ${logical} FAILED — required dependency" >&2
                return 1
            fi
        fi
    done
}

# ─── Special: install yt-dlp via pip (always latest) ─────────────────────────
oiu_deps_install_ytdlp() {
    if command -v yt-dlp &>/dev/null; then
        echo "  $(printf '\033[32m')✓$(printf '\033[0m') yt-dlp $(yt-dlp --version 2>/dev/null) (already installed)"
        return 0
    fi

    echo "  $(printf '\033[36m')→$(printf '\033[0m') Installing yt-dlp via pip..."
    local installed=0

    if [[ -n "$OIU_PIP" ]]; then
        if [[ "$OIU_PIP" == "pipx" ]]; then
            pipx install yt-dlp && installed=1
        else
            $OIU_PIP install --upgrade yt-dlp --break-system-packages 2>/dev/null && installed=1 || \
            $OIU_PIP install --upgrade yt-dlp 2>/dev/null && installed=1 || \
            $OIU_PIP install --upgrade --user yt-dlp && installed=1
        fi
    fi

    if [[ $installed -eq 1 ]] && command -v yt-dlp &>/dev/null; then
        echo "  $(printf '\033[32m')✓$(printf '\033[0m') yt-dlp $(yt-dlp --version 2>/dev/null)"
    else
        echo "  $(printf '\033[31m')✗$(printf '\033[0m') yt-dlp installation failed — install manually" >&2
        return 1
    fi
}

export -f _oiu_priv _oiu_pm_update _oiu_pm_install _oiu_pkg_installed
export -f oiu_deps_install oiu_deps_install_ytdlp
