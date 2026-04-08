#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# OIU — updater.sh
# Handles update checking, downloading, building and installing new versions.
# Supports: update channels (stable/beta/etc), VERSION files, rollback.
# Requires: system.sh, registry.sh, builder.sh sourced first.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Fetch remote version ─────────────────────────────────────────────────────
# Usage: oiu_update_fetch_remote_version "url"
# Prints version string, returns 1 on failure
oiu_update_fetch_remote_version() {
    local url="$1"
    local version=""

    # Cache-bust with timestamp
    local bust_url="${url}?$(date +%s)"

    if command -v curl &>/dev/null; then
        version=$(curl -fsSL --max-time 10 \
            -H "Cache-Control: no-cache, no-store" \
            -H "Pragma: no-cache" \
            "$bust_url" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget &>/dev/null; then
        version=$(wget -qO- --timeout=10 "$url" 2>/dev/null | tr -d '[:space:]')
    else
        echo "  [!] Neither curl nor wget found — cannot check for updates" >&2
        return 1
    fi

    [[ -z "$version" ]] && return 1
    echo "$version"
}

# ─── Semantic version comparison ─────────────────────────────────────────────
# oiu_version_lt A B  → returns 0 if A < B, 1 otherwise
oiu_version_lt() {
    local a="$1" b="$2"
    # Strip channel suffixes (e.g. 1.2.3-beta → 1.2.3)
    a="${a%%-*}"; b="${b%%-*}"

    IFS=. read -r a1 a2 a3 <<< "$a"
    IFS=. read -r b1 b2 b3 <<< "$b"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}

    ((a1 < b1)) && return 0
    ((a1 > b1)) && return 1
    ((a2 < b2)) && return 0
    ((a2 > b2)) && return 1
    ((a3 < b3)) && return 0
    return 1
}

# ─── Check for update (non-destructive) ──────────────────────────────────────
# Usage: oiu_update_check "appname"
# Returns 0 if update available, sets OIU_UPDATE_REMOTE_VERSION
# Returns 1 if up to date or check failed
oiu_update_check() {
    local app="$1"
    local update_url; update_url=$(oiu_registry_get "$app" "update_url") || return 1
    local local_ver;  local_ver=$(oiu_registry_get "$app"  "version")    || return 1

    local remote_ver
    remote_ver=$(oiu_update_fetch_remote_version "$update_url") || return 1

    OIU_UPDATE_REMOTE_VERSION="$remote_ver"
    OIU_UPDATE_LOCAL_VERSION="$local_ver"
    export OIU_UPDATE_REMOTE_VERSION OIU_UPDATE_LOCAL_VERSION

    if [[ "$local_ver" == "$remote_ver" ]]; then
        return 1   # up to date
    fi

    oiu_version_lt "$local_ver" "$remote_ver" && return 0   # update available
    return 1   # local is newer (dev version)
}

# ─── Build update URL from channel ────────────────────────────────────────────
# Builds the raw VERSION url for a given channel/branch.
# If update_url is already set in registry, use it. Otherwise build from github_repo.
# Channels: stable (main/master), beta, nightly, or any branch name.
oiu_update_url_for_channel() {
    local app="$1" channel="${2:-stable}"
    local repo; repo=$(oiu_registry_get "$app" "github_repo") 2>/dev/null

    [[ -z "$repo" ]] && {
        oiu_registry_get "$app" "update_url" 2>/dev/null
        return
    }

    local branch="main"
    case "$channel" in
        stable)  branch="main" ;;
        beta)    branch="beta" ;;
        nightly) branch="nightly" ;;
        *)       branch="$channel" ;;   # use as-is (custom branch name)
    esac

    echo "https://raw.githubusercontent.com/${repo}/${branch}/VERSION"
}

# ─── Perform the update ───────────────────────────────────────────────────────
# Usage: oiu_update_run "appname" [--yes] [--channel stable|beta|nightly|branch]
oiu_update_run() {
    local app="$1"; shift
    local auto_yes=0
    local channel=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)       auto_yes=1 ;;
            --channel)      channel="$2"; shift ;;
            --channel=*)    channel="${1#--channel=}" ;;
        esac
        shift
    done

    # Get install info from registry
    local install_scope; install_scope=$(oiu_registry_get "$app" "install_scope") || install_scope="user"
    local install_path;  install_path=$(oiu_registry_get  "$app" "binary_path")  || {
        echo "  ✗ $app is not registered. Run: oiu install" >&2; return 1
    }
    local github_repo;   github_repo=$(oiu_registry_get   "$app" "github_repo")  || {
        echo "  ✗ No GitHub repo registered for $app" >&2; return 1
    }
    local current_ver;   current_ver=$(oiu_registry_get   "$app" "version")
    local update_mode;   update_mode=$(oiu_registry_get   "$app" "update_mode")  || update_mode="manual"

    # Resolve channel → VERSION url
    if [[ -z "$channel" ]]; then
        channel=$(oiu_registry_get "$app" "update_channel" 2>/dev/null || echo "stable")
    fi
    local version_url; version_url=$(oiu_update_url_for_channel "$app" "$channel")

    # Fetch remote version
    echo "  → Checking ${channel} channel..."
    local remote_ver
    remote_ver=$(oiu_update_fetch_remote_version "$version_url") || {
        echo "  ✗ Could not reach update server. Check your connection." >&2
        echo "    Current version $current_ver still installed and working." >&2
        return 1
    }

    # Compare
    if [[ "$current_ver" == "$remote_ver" ]]; then
        echo "  ✓ Already up to date ($current_ver)"
        return 0
    fi

    if ! oiu_version_lt "$current_ver" "$remote_ver"; then
        echo "  ✓ Local version ($current_ver) is newer than ${channel} ($remote_ver) — dev build"
        return 0
    fi

    echo ""
    echo "  Update available: $current_ver → $remote_ver  [$channel]"
    echo ""

    # Respect update_mode
    if [[ "$update_mode" == "notify" && "$auto_yes" -eq 0 ]]; then
        echo "  Run: oiu update $app  to install"
        return 0
    fi

    if [[ "$update_mode" == "off" ]]; then
        echo "  Updates are disabled for $app (update_mode=off)"
        return 0
    fi

    if [[ "$auto_yes" -eq 0 ]]; then
        read -rp "  Install update? [y/N] " _reply
        echo ""
        [[ ! "$_reply" =~ ^[Yy]$ ]] && { echo "  Cancelled."; return 0; }
    fi

    # ── Do the update ────────────────────────────────────────────────────────

    # 1. Backup current binary
    local backup_path="${install_path}.oiu-backup"
    echo "  → Backing up current binary..."
    if [[ -f "$install_path" ]]; then
        cp "$install_path" "$backup_path" 2>/dev/null || \
            $OIU_SUDO cp "$install_path" "$backup_path" 2>/dev/null || true
        echo "  ✓ Backup: $backup_path"
    fi

    # 2. Clone fresh copy to temp dir
    local tmp_dir
    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t oiu_update)
    trap 'rm -rf "$tmp_dir"' EXIT

    local repo_url="https://github.com/${github_repo}"
    local clone_branch="main"
    [[ "$channel" != "stable" ]] && clone_branch="$channel"

    echo "  → Downloading $app $remote_ver..."
    git clone --depth 1 --branch "$clone_branch" "$repo_url" "$tmp_dir/src" 2>/dev/null || \
    git clone --depth 1 "$repo_url" "$tmp_dir/src" || {
        echo "  ✗ Git clone failed" >&2
        _oiu_update_rollback "$app" "$install_path" "$backup_path"
        return 1
    }

    # 3. Build
    echo "  → Building $app $remote_ver..."
    cd "$tmp_dir/src" || return 1

    # Load build config from the newly cloned source
    OIU_CONF_DIR="."
    source "$OIU_DIR/core/builder.sh"
    oiu_builder_load_conf
    oiu_builder_detect_system

    # macOS brew paths
    if [[ "$OIU_OS" == "macos" ]] && command -v brew &>/dev/null; then
        local bp; bp="$(brew --prefix)"
        export PKG_CONFIG_PATH="$bp/opt/ncurses/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
        export LDFLAGS="-L$bp/opt/ncurses/lib ${LDFLAGS:-}"
        export CPPFLAGS="-I$bp/opt/ncurses/include ${CPPFLAGS:-}"
    fi

    if ! oiu_builder_build; then
        echo "  ✗ Build failed" >&2
        _oiu_update_rollback "$app" "$install_path" "$backup_path"
        cd - >/dev/null
        return 1
    fi

    # 4. Find the new binary
    local new_binary
    OIU_BUILD_BINARY=$(oiu_registry_get "$app" "binary_path" | xargs basename 2>/dev/null || echo "$app")
    new_binary=$(oiu_builder_find_binary) || {
        echo "  ✗ Built binary not found" >&2
        _oiu_update_rollback "$app" "$install_path" "$backup_path"
        cd - >/dev/null
        return 1
    }

    # 5. Install new binary
    echo "  → Installing new binary..."
    if [[ -w "$(dirname "$install_path")" ]]; then
        cp "$new_binary" "$install_path" && chmod 755 "$install_path"
    else
        $OIU_SUDO cp "$new_binary" "$install_path" && \
        $OIU_SUDO chmod 755 "$install_path"
    fi || {
        echo "  ✗ Install failed" >&2
        _oiu_update_rollback "$app" "$install_path" "$backup_path"
        cd - >/dev/null
        return 1
    }

    # 6. Update registry
    oiu_registry_write "$app" version="$remote_ver" update_channel="$channel"

    # 7. Clean up backup
    rm -f "$backup_path" 2>/dev/null || $OIU_SUDO rm -f "$backup_path" 2>/dev/null || true

    cd - >/dev/null
    echo ""
    echo "  ✓ Updated to $remote_ver"
    return 0
}

# ─── Rollback helper ─────────────────────────────────────────────────────────
_oiu_update_rollback() {
    local app="$1" install_path="$2" backup_path="$3"
    if [[ -f "$backup_path" ]]; then
        echo "  → Rolling back to previous version..."
        cp "$backup_path" "$install_path" 2>/dev/null || \
            $OIU_SUDO cp "$backup_path" "$install_path" 2>/dev/null || true
        rm -f "$backup_path" 2>/dev/null || true
        echo "  ✓ Rollback complete — previous version restored"
    fi
}

export -f oiu_update_fetch_remote_version oiu_version_lt
export -f oiu_update_check oiu_update_url_for_channel
export -f oiu_update_run _oiu_update_rollback
