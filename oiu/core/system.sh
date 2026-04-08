#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# OIU — system.sh
# Platform detection layer. Detects everything once, exports OIU_* variables.
# Every other OIU component sources this. Never makes decisions — only facts.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── OS ─────────────────────────────────────────────────────────────────────────
_raw_os="$(uname -s 2>/dev/null)"
case "$_raw_os" in
    Linux*)     OIU_OS="linux"     ;;
    Darwin*)    OIU_OS="macos"     ;;
    FreeBSD*)   OIU_OS="freebsd"   ;;
    NetBSD*)    OIU_OS="netbsd"    ;;
    OpenBSD*)   OIU_OS="openbsd"   ;;
    DragonFly*) OIU_OS="dragonfly" ;;
    MINGW*|MSYS*|CYGWIN*) OIU_OS="wsl" ;;
    *)          OIU_OS="unknown"   ;;
esac

# WSL detection (Linux kernel but Windows host)
if [[ "$OIU_OS" == "linux" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    OIU_OS="wsl"
fi

# ─── Distro (Linux/WSL only) ─────────────────────────────────────────────────
OIU_DISTRO=""
OIU_DISTRO_VERSION=""
if [[ "$OIU_OS" == "linux" || "$OIU_OS" == "wsl" ]]; then
    if [[ -f /etc/os-release ]]; then
        OIU_DISTRO=$(source /etc/os-release 2>/dev/null; echo "${ID:-unknown}")
        OIU_DISTRO_VERSION=$(source /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
    elif [[ -f /etc/arch-release ]]; then
        OIU_DISTRO="arch"
    elif [[ -f /etc/debian_version ]]; then
        OIU_DISTRO="debian"
        OIU_DISTRO_VERSION=$(cat /etc/debian_version)
    fi
fi

# ─── Architecture ────────────────────────────────────────────────────────────
_raw_arch="$(uname -m 2>/dev/null)"
case "$_raw_arch" in
    x86_64|amd64)   OIU_ARCH="x86_64"  ; OIU_BITS="64" ;;
    aarch64|arm64)  OIU_ARCH="arm64"   ; OIU_BITS="64" ;;
    armv7*|armhf)   OIU_ARCH="armv7"   ; OIU_BITS="32" ;;
    i386|i686)      OIU_ARCH="i386"    ; OIU_BITS="32" ;;
    riscv64)        OIU_ARCH="riscv64" ; OIU_BITS="64" ;;
    *)              OIU_ARCH="$_raw_arch" ; OIU_BITS="64" ;;
esac

# Can this system run 32-bit binaries?
OIU_32BIT_SUPPORT="no"
if [[ "$OIU_BITS" == "64" ]]; then
    # Linux: check for multilib
    if [[ "$OIU_OS" == "linux" || "$OIU_OS" == "wsl" ]]; then
        [[ -f /lib/ld-linux.so.2 ]] || [[ -d /lib32 ]] && OIU_32BIT_SUPPORT="yes"
    fi
    # macOS always supports both on Intel; Apple Silicon only with Rosetta
    if [[ "$OIU_OS" == "macos" ]]; then
        if [[ "$OIU_ARCH" == "x86_64" ]]; then
            OIU_32BIT_SUPPORT="yes"
        elif sysctl -n soc.subtype 2>/dev/null | grep -q .; then
            # Apple Silicon — check Rosetta
            /usr/bin/arch -x86_64 true 2>/dev/null && OIU_32BIT_SUPPORT="yes"
        fi
    fi
fi

# ─── Package Manager ─────────────────────────────────────────────────────────
OIU_PKG_MANAGER="unknown"
if [[ "$OIU_OS" == "macos" ]]; then
    if   command -v brew      &>/dev/null; then OIU_PKG_MANAGER="brew"
    elif command -v port      &>/dev/null; then OIU_PKG_MANAGER="macports"
    fi
elif [[ "$OIU_OS" == "freebsd" || "$OIU_OS" == "dragonfly" ]]; then
    command -v pkg            &>/dev/null && OIU_PKG_MANAGER="pkg"
elif [[ "$OIU_OS" == "netbsd" ]]; then
    command -v pkgin          &>/dev/null && OIU_PKG_MANAGER="pkgin"
elif [[ "$OIU_OS" == "openbsd" ]]; then
    command -v pkg_add        &>/dev/null && OIU_PKG_MANAGER="pkg_add"
else
    # Linux / WSL — ordered by specificity
    if   command -v apt-get      &>/dev/null; then OIU_PKG_MANAGER="apt"
    elif command -v pacman       &>/dev/null; then OIU_PKG_MANAGER="pacman"
    elif command -v dnf          &>/dev/null; then OIU_PKG_MANAGER="dnf"
    elif command -v yum          &>/dev/null; then OIU_PKG_MANAGER="yum"
    elif command -v zypper       &>/dev/null; then OIU_PKG_MANAGER="zypper"
    elif command -v apk          &>/dev/null; then OIU_PKG_MANAGER="apk"
    elif command -v emerge       &>/dev/null; then OIU_PKG_MANAGER="emerge"
    elif command -v xbps-install &>/dev/null; then OIU_PKG_MANAGER="xbps"
    elif command -v pkg          &>/dev/null; then OIU_PKG_MANAGER="pkg"
    fi
fi

# Secondary package managers (supplementary, not primary)
OIU_PKG_MANAGER_ALT=""
if command -v flatpak &>/dev/null; then OIU_PKG_MANAGER_ALT="flatpak"; fi
if command -v snap    &>/dev/null; then OIU_PKG_MANAGER_ALT="${OIU_PKG_MANAGER_ALT:+$OIU_PKG_MANAGER_ALT,}snap"; fi

# ─── Display Server ──────────────────────────────────────────────────────────
OIU_DISPLAY="none"
if [[ "$OIU_OS" == "macos" ]]; then
    OIU_DISPLAY="quartz"
elif [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    OIU_DISPLAY="wayland"
elif [[ -n "${DISPLAY:-}" ]]; then
    OIU_DISPLAY="x11"
elif [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
    OIU_DISPLAY="x11"
fi

# ─── Browser (for GUI installer) ─────────────────────────────────────────────
OIU_BROWSER=""
if [[ "$OIU_OS" == "macos" ]]; then
    OIU_BROWSER="open"
elif command -v xdg-open  &>/dev/null; then OIU_BROWSER="xdg-open"
elif command -v firefox   &>/dev/null; then OIU_BROWSER="firefox"
elif command -v chromium  &>/dev/null; then OIU_BROWSER="chromium"
elif command -v google-chrome &>/dev/null; then OIU_BROWSER="google-chrome"
fi

# Can we launch a GUI?
OIU_CAN_GUI="no"
if [[ "$OIU_DISPLAY" != "none" && -n "$OIU_BROWSER" ]]; then
    OIU_CAN_GUI="yes"
fi

# ─── libc ────────────────────────────────────────────────────────────────────
OIU_LIBC="unknown"
if [[ "$OIU_OS" == "linux" || "$OIU_OS" == "wsl" ]]; then
    if ldd --version 2>&1 | grep -qi musl; then
        OIU_LIBC="musl"
    elif ldd --version 2>&1 | grep -qi gnu; then
        OIU_LIBC="glibc"
    elif [[ -f /lib/ld-musl*.so* ]] || [[ -f /lib/libc.musl*.so* ]]; then
        OIU_LIBC="musl"
    else
        OIU_LIBC="glibc"  # safe default for most Linux
    fi
elif [[ "$OIU_OS" == "macos" ]]; then
    OIU_LIBC="libSystem"
elif [[ "$OIU_OS" =~ ^(freebsd|netbsd|openbsd|dragonfly)$ ]]; then
    OIU_LIBC="bsdlibc"
fi

# ─── Shell ───────────────────────────────────────────────────────────────────
OIU_SHELL="sh"
if   [[ -n "${BASH_VERSION:-}" ]]; then OIU_SHELL="bash"
elif [[ -n "${ZSH_VERSION:-}"  ]]; then OIU_SHELL="zsh"
elif [[ "$(basename "${SHELL:-}")" == "fish" ]]; then OIU_SHELL="fish"
fi

# ─── Privilege escalation ────────────────────────────────────────────────────
OIU_SUDO="none"
if   command -v sudo &>/dev/null; then OIU_SUDO="sudo"
elif command -v doas &>/dev/null; then OIU_SUDO="doas"
fi

OIU_IS_ROOT="no"
[[ "${EUID:-$(id -u)}" -eq 0 ]] && OIU_IS_ROOT="yes"

# ─── Environment flags ───────────────────────────────────────────────────────
OIU_IS_CI="no"
[[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" || -n "${TRAVIS:-}" || -n "${CIRCLECI:-}" || -n "${JENKINS_URL:-}" ]] \
    && OIU_IS_CI="yes"

OIU_IS_CONTAINER="no"
if [[ -f /.dockerenv ]] || grep -q 'lxc\|docker\|container' /proc/1/cgroup 2>/dev/null; then
    OIU_IS_CONTAINER="yes"
fi

# ─── VM detection ────────────────────────────────────────────────────────────
OIU_IS_VM="no"
if command -v systemd-detect-virt &>/dev/null; then
    _virt=$(systemd-detect-virt 2>/dev/null)
    [[ "$_virt" != "none" && -n "$_virt" ]] && OIU_IS_VM="yes"
elif [[ -f /sys/class/dmi/id/product_name ]]; then
    _prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [[ "$_prod" =~ (vmware|virtualbox|qemu|kvm|xen|hyper-v) ]] && OIU_IS_VM="yes"
fi

# ─── Hardware notes ──────────────────────────────────────────────────────────
OIU_HW_WEIRD=""
if [[ "$OIU_OS" == "macos" && "$OIU_ARCH" == "arm64" ]]; then
    OIU_HW_WEIRD="apple_silicon"
fi
if grep -qi "raspberry pi" /proc/cpuinfo 2>/dev/null; then
    OIU_HW_WEIRD="raspberry_pi"
fi

# ─── Make command (BSD uses gmake) ───────────────────────────────────────────
OIU_MAKE="make"
if command -v gmake &>/dev/null && [[ "$OIU_OS" =~ ^(freebsd|netbsd|openbsd|dragonfly)$ ]]; then
    OIU_MAKE="gmake"
fi

# ─── User & home ─────────────────────────────────────────────────────────────
OIU_USER="${USER:-$(whoami 2>/dev/null)}"
OIU_HOME="${HOME:-/root}"

# ─── Python detection ────────────────────────────────────────────────────────
OIU_PYTHON=""
OIU_PIP=""
if   command -v python3 &>/dev/null; then OIU_PYTHON="python3"
elif command -v python  &>/dev/null && python --version 2>&1 | grep -q "^Python 3"; then
    OIU_PYTHON="python"
fi
if   command -v pip3 &>/dev/null; then OIU_PIP="pip3"
elif command -v pip  &>/dev/null; then OIU_PIP="pip"
elif command -v pipx &>/dev/null; then OIU_PIP="pipx"
fi

# ─── .NET / Mono detection ────────────────────────────────────────────────────
OIU_DOTNET=""
if   command -v dotnet &>/dev/null; then OIU_DOTNET="dotnet"
elif command -v mono   &>/dev/null; then OIU_DOTNET="mono"
fi

# ─── Export all ──────────────────────────────────────────────────────────────
export OIU_OS OIU_DISTRO OIU_DISTRO_VERSION
export OIU_ARCH OIU_BITS OIU_32BIT_SUPPORT
export OIU_PKG_MANAGER OIU_PKG_MANAGER_ALT
export OIU_DISPLAY OIU_BROWSER OIU_CAN_GUI
export OIU_LIBC OIU_SHELL
export OIU_SUDO OIU_IS_ROOT
export OIU_IS_CI OIU_IS_CONTAINER OIU_IS_VM
export OIU_HW_WEIRD OIU_MAKE
export OIU_USER OIU_HOME
export OIU_PYTHON OIU_PIP OIU_DOTNET

# ─── Optional: print summary if run directly ─────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo ""
    echo "  OIU System Detection"
    echo "  ────────────────────────────────────────"
    printf "  %-22s %s\n" "OS:"          "$OIU_OS"
    printf "  %-22s %s\n" "Distro:"      "${OIU_DISTRO:-n/a} ${OIU_DISTRO_VERSION}"
    printf "  %-22s %s\n" "Arch:"        "$OIU_ARCH ($OIU_BITS-bit)"
    printf "  %-22s %s\n" "32-bit support:" "$OIU_32BIT_SUPPORT"
    printf "  %-22s %s\n" "Package manager:" "$OIU_PKG_MANAGER"
    printf "  %-22s %s\n" "Alt PM:"      "${OIU_PKG_MANAGER_ALT:-none}"
    printf "  %-22s %s\n" "Display:"     "$OIU_DISPLAY"
    printf "  %-22s %s\n" "Can GUI:"     "$OIU_CAN_GUI"
    printf "  %-22s %s\n" "libc:"        "$OIU_LIBC"
    printf "  %-22s %s\n" "Shell:"       "$OIU_SHELL"
    printf "  %-22s %s\n" "Sudo:"        "$OIU_SUDO"
    printf "  %-22s %s\n" "Root:"        "$OIU_IS_ROOT"
    printf "  %-22s %s\n" "CI env:"      "$OIU_IS_CI"
    printf "  %-22s %s\n" "Container:"   "$OIU_IS_CONTAINER"
    printf "  %-22s %s\n" "VM:"          "$OIU_IS_VM"
    printf "  %-22s %s\n" "HW notes:"    "${OIU_HW_WEIRD:-none}"
    printf "  %-22s %s\n" "Make cmd:"    "$OIU_MAKE"
    printf "  %-22s %s\n" "Python:"      "${OIU_PYTHON:-not found}"
    printf "  %-22s %s\n" "pip:"         "${OIU_PIP:-not found}"
    printf "  %-22s %s\n" ".NET/Mono:"   "${OIU_DOTNET:-not found}"
    echo ""
fi
