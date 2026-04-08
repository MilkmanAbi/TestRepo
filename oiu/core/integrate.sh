#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# OIU — integrate.sh
# Post-install integration: .desktop file, icons, macOS app bundle,
# uninstaller generation, upgrade hook injection.
# Requires: system.sh, registry.sh sourced first. oiu.conf parsed.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Parse integration fields from oiu.conf ───────────────────────────────────
oiu_integrate_load_conf() {
    local conf="${OIU_CONF_FILE:-oiu.conf}"
    [[ ! -f "$conf" ]] && return 0

    OIU_APP_DISPLAY_NAME=""
    OIU_APP_ICON=""
    OIU_APP_DESKTOP_CATEGORY="Utility"
    OIU_APP_DESKTOP_COMMENT=""

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        # Skip section headers
        [[ "$line" =~ ^\[.*\]$ ]] && continue

        local key val
        key="${line%%=*}"; val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"

        case "$key" in
            display_name)      OIU_APP_DISPLAY_NAME="$val"      ;;
            icon)              OIU_APP_ICON="$val"              ;;
            desktop_category)  OIU_APP_DESKTOP_CATEGORY="$val"  ;;
            desktop_comment)   OIU_APP_DESKTOP_COMMENT="$val"   ;;
        esac
    done < "$conf"

    OIU_APP_DISPLAY_NAME="${OIU_APP_DISPLAY_NAME:-$OIU_APP_NAME}"
    export OIU_APP_DISPLAY_NAME OIU_APP_ICON OIU_APP_DESKTOP_CATEGORY OIU_APP_DESKTOP_COMMENT
}

# ─── Linux: install .desktop file + icon ─────────────────────────────────────
oiu_integrate_linux_desktop() {
    local app="$OIU_APP_NAME"
    local binary_path="$1"
    local scope="${OIU_SCOPE:-user}"

    # Determine paths based on scope
    local desktop_dir icon_dir
    if [[ "$scope" == "system" ]]; then
        desktop_dir="/usr/share/applications"
        icon_dir="/usr/share/icons/hicolor/256x256/apps"
    else
        desktop_dir="$OIU_HOME/.local/share/applications"
        icon_dir="$OIU_HOME/.local/share/icons/hicolor/256x256/apps"
    fi

    local placed_files=()

    # ── .desktop file ────────────────────────────────────────────────────────
    local desktop_file="$desktop_dir/${app}.desktop"
    local desktop_content="[Desktop Entry]
Name=${OIU_APP_DISPLAY_NAME:-$app}
Exec=$binary_path
Terminal=true
Type=Application
Categories=${OIU_APP_DESKTOP_CATEGORY:-Utility};
Comment=${OIU_APP_DESKTOP_COMMENT:-}
"
    # Add icon line if icon exists
    if [[ -n "$OIU_APP_ICON" && -f "$OIU_APP_ICON" ]]; then
        desktop_content+="Icon=${app}
"
    fi

    if [[ "$scope" == "system" ]]; then
        $OIU_SUDO mkdir -p "$desktop_dir"
        echo "$desktop_content" | $OIU_SUDO tee "$desktop_file" >/dev/null
        $OIU_SUDO chmod 644 "$desktop_file"
    else
        mkdir -p "$desktop_dir"
        echo "$desktop_content" > "$desktop_file"
        chmod 644 "$desktop_file"
    fi
    placed_files+=("$desktop_file")
    echo "  ✓ .desktop file → $desktop_file"

    # ── Icon ─────────────────────────────────────────────────────────────────
    if [[ -n "$OIU_APP_ICON" && -f "$OIU_APP_ICON" ]]; then
        if [[ "$scope" == "system" ]]; then
            $OIU_SUDO mkdir -p "$icon_dir"
            $OIU_SUDO cp "$OIU_APP_ICON" "$icon_dir/${app}.png"
        else
            mkdir -p "$icon_dir"
            cp "$OIU_APP_ICON" "$icon_dir/${app}.png"
        fi
        placed_files+=("$icon_dir/${app}.png")
        echo "  ✓ Icon → $icon_dir/${app}.png"

        # Refresh icon cache
        if command -v gtk-update-icon-cache &>/dev/null; then
            gtk-update-icon-cache -f -t "$(dirname "$(dirname "$icon_dir")")" 2>/dev/null || true
        fi
        if command -v xdg-icon-resource &>/dev/null && [[ "$scope" != "system" ]]; then
            xdg-icon-resource install --novendor --size 256 "$OIU_APP_ICON" "$app" 2>/dev/null || true
        fi
    fi

    # Update desktop database
    if command -v update-desktop-database &>/dev/null; then
        if [[ "$scope" == "system" ]]; then
            $OIU_SUDO update-desktop-database "$desktop_dir" 2>/dev/null || true
        else
            update-desktop-database "$desktop_dir" 2>/dev/null || true
        fi
    fi

    # Return list of placed files (newline-separated) for manifest
    printf '%s\n' "${placed_files[@]}"
}

# ─── macOS: create .app bundle / Launchpad entry ─────────────────────────────
oiu_integrate_macos_app() {
    local app="$OIU_APP_NAME"
    local binary_path="$1"
    local display="${OIU_APP_DISPLAY_NAME:-$app}"
    local scope="${OIU_SCOPE:-user}"

    # Install location
    local apps_dir
    if [[ "$scope" == "system" ]]; then
        apps_dir="/Applications"
    else
        apps_dir="$OIU_HOME/Applications"
    fi

    # Skip app bundle if no icon (terminal app with no GUI component)
    if [[ -z "$OIU_APP_ICON" || ! -f "$OIU_APP_ICON" ]]; then
        echo "  ○ macOS app bundle skipped (no icon set in oiu.conf)"
        return 0
    fi

    local bundle_dir="$apps_dir/${display}.app"
    local contents_dir="$bundle_dir/Contents"
    local macos_dir="$contents_dir/MacOS"
    local resources_dir="$contents_dir/Resources"

    mkdir -p "$macos_dir" "$resources_dir" || \
        $OIU_SUDO mkdir -p "$macos_dir" "$resources_dir"

    # Launcher script inside bundle
    cat > "$macos_dir/${app}" <<LAUNCH
#!/bin/bash
exec "$binary_path" "\$@"
LAUNCH
    chmod 755 "$macos_dir/${app}"

    # Convert PNG to ICNS if sips is available (macOS built-in)
    if command -v sips &>/dev/null && command -v iconutil &>/dev/null; then
        local iconset_dir="$resources_dir/${app}.iconset"
        mkdir -p "$iconset_dir"
        local sizes=(16 32 64 128 256 512)
        for s in "${sizes[@]}"; do
            sips -z "$s" "$s" "$OIU_APP_ICON" \
                --out "$iconset_dir/icon_${s}x${s}.png" 2>/dev/null || true
            sips -z $((s*2)) $((s*2)) "$OIU_APP_ICON" \
                --out "$iconset_dir/icon_${s}x${s}@2x.png" 2>/dev/null || true
        done
        iconutil -c icns "$iconset_dir" -o "$resources_dir/${app}.icns" 2>/dev/null && \
            echo "  ✓ Icon converted to ICNS"
        rm -rf "$iconset_dir"
    else
        # Fallback: just copy PNG
        cp "$OIU_APP_ICON" "$resources_dir/${app}.png" 2>/dev/null || true
    fi

    local icns_path="$resources_dir/${app}.icns"
    [[ ! -f "$icns_path" ]] && icns_path=""

    # Info.plist
    local version="${OIU_APP_VERSION:-1.0.0}"
    cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>${app}</string>
    <key>CFBundleIdentifier</key>       <string>com.oiu.${app}</string>
    <key>CFBundleName</key>             <string>${display}</string>
    <key>CFBundleVersion</key>          <string>${version}</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSUIElement</key>              <true/>
    $( [[ -n "$icns_path" ]] && echo "<key>CFBundleIconFile</key><string>${app}</string>" )
</dict>
</plist>
PLIST

    # Register with Launch Services
    if command -v /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister &>/dev/null; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -f "$bundle_dir" 2>/dev/null || true
    fi

    echo "  ✓ macOS app bundle → $bundle_dir"
    echo "$bundle_dir"
}

# ─── Generate the uninstaller for this app ────────────────────────────────────
oiu_integrate_generate_uninstaller() {
    local app="$OIU_APP_NAME"
    local scope="${OIU_SCOPE:-user}"

    local uninstaller_dir
    if [[ "$scope" == "system" ]]; then
        uninstaller_dir="/usr/local/share/oiu/uninstallers"
    else
        uninstaller_dir="$OIU_HOME/.local/share/oiu/uninstallers"
    fi

    mkdir -p "$uninstaller_dir" 2>/dev/null || \
        $OIU_SUDO mkdir -p "$uninstaller_dir"

    local uninstaller_path="$uninstaller_dir/${app}.sh"

    cat > "$uninstaller_path" <<UNINSTALLER
#!/usr/bin/env bash
# OIU-generated uninstaller for: $app
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# DO NOT EDIT — regenerated on each install

OIU_DIR="\${OIU_DIR:-$(dirname "$(dirname "$0")")}"
OIU_REGISTRY="${OIU_REGISTRY}"

if [[ -t 1 ]]; then
    GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BOLD=''; RESET=''
fi

ok()   { echo -e "  \${GREEN}✓\${RESET} \$*"; }
warn() { echo -e "  \${YELLOW}!\${RESET} \$*"; }
die()  { echo -e "  \${RED}✗\${RESET} \$*"; exit 1; }

echo ""
echo -e "\${BOLD}Uninstalling $app...\${RESET}"
echo ""

if [[ "\$1" != "--yes" && "\$1" != "-y" ]]; then
    read -rp "  Remove $app and all its files? [y/N] " _r
    echo ""
    [[ ! "\$_r" =~ ^[Yy]\$ ]] && { echo "  Cancelled."; exit 0; }
fi

# Ask about user data
_keep_data="yes"
if [[ "\$1" != "--purge" ]]; then
    read -rp "  Keep config and user data? [Y/n] " _kd
    echo ""
    [[ "\$_kd" =~ ^[Nn]\$ ]] && _keep_data="no"
fi

# Read manifest from registry and remove each file
if command -v python3 &>/dev/null && [[ -f "\$OIU_REGISTRY" ]]; then
    OIU_REG_PATH="\$OIU_REGISTRY" OIU_REG_APP="$app" \
    python3 - <<'PYEOF'
import json, os
reg = json.load(open(os.environ['OIU_REG_PATH']))
for f in reg.get('apps', {}).get(os.environ['OIU_REG_APP'], {}).get('manifest', []):
    print(f)
PYEOF
else
    # Hardcoded manifest fallback (set at install time)
$(oiu_registry_manifest "$app" | while read -r f; do echo "    echo \"$f\""; done)
fi | while read -r target; do
    [[ -z "\$target" ]] && continue

    # Skip user data directories if keeping data
    if [[ "\$_keep_data" == "yes" ]]; then
        [[ "\$target" == *"/.config/$app"* ]]      && continue
        [[ "\$target" == *"/.local/share/$app"* ]] && continue
        [[ "\$target" == *"/.cache/$app"* ]]       && continue
    fi

    if [[ -f "\$target" ]]; then
        rm -f "\$target" 2>/dev/null || sudo rm -f "\$target" 2>/dev/null || warn "Could not remove: \$target"
        ok "Removed: \$target"
    elif [[ -d "\$target" ]]; then
        rm -rf "\$target" 2>/dev/null || sudo rm -rf "\$target" 2>/dev/null || warn "Could not remove: \$target"
        ok "Removed: \$target"
    fi
done

# Remove from OIU registry
if command -v python3 &>/dev/null && [[ -f "\$OIU_REGISTRY" ]]; then
    OIU_REG_PATH="\$OIU_REGISTRY" OIU_REG_APP="$app" python3 - <<'PYEOF'
import json, os
path = os.environ['OIU_REG_PATH']
r = json.load(open(path))
r['apps'].pop(os.environ['OIU_REG_APP'], None)
json.dump(r, open(path,'w'), indent=2)
PYEOF
fi

# Remove this uninstaller itself
rm -f "\$0"

echo ""
ok "$app uninstalled successfully."
echo ""
UNINSTALLER

    chmod 755 "$uninstaller_path"
    echo "  ✓ Uninstaller → $uninstaller_path"
    echo "$uninstaller_path"
}

# ─── Run full integration ─────────────────────────────────────────────────────
oiu_integrate_run() {
    local binary_path="$1"

    oiu_integrate_load_conf

    local extra_files=()

    case "$OIU_OS" in
        linux|wsl)
            mapfile -t extra < <(oiu_integrate_linux_desktop "$binary_path")
            extra_files+=("${extra[@]}")
            ;;
        macos)
            mapfile -t extra < <(oiu_integrate_macos_app "$binary_path")
            extra_files+=("${extra[@]}")
            ;;
    esac

    # Generate uninstaller and record its path
    local uninstaller_path
    uninstaller_path=$(oiu_integrate_generate_uninstaller)
    extra_files+=("$uninstaller_path")

    # Update registry: add extra files to manifest, record uninstaller
    oiu_registry_write "$OIU_APP_NAME" \
        uninstaller="$uninstaller_path"

    # Append extra_files to manifest in registry
    if [[ ${#extra_files[@]} -gt 0 ]]; then
        local current_manifest
        current_manifest=$(oiu_registry_manifest "$OIU_APP_NAME" 2>/dev/null || true)
        local new_manifest="$current_manifest"
        for f in "${extra_files[@]}"; do
            [[ -n "$f" ]] && new_manifest+=$'\n'"$f"
        done
        oiu_registry_write "$OIU_APP_NAME" manifest="$new_manifest"
    fi
}

export -f oiu_integrate_load_conf oiu_integrate_linux_desktop
export -f oiu_integrate_macos_app oiu_integrate_generate_uninstaller
export -f oiu_integrate_run
