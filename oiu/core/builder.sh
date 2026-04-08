#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# OIU — builder.sh
# Builds the project from source. Reads builder.conf.
# Supports: C, C++ (make/cmake/raw), C# (.NET/mono), Python (no build / venv)
# Requires: system.sh sourced first.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Parse builder.conf ───────────────────────────────────────────────────────
# Sets OIU_BUILD_* variables. Reads from $OIU_CONF_DIR/builder.conf
oiu_builder_load_conf() {
    local conf="${OIU_CONF_DIR:-.}/builder.conf"

    # Defaults
    OIU_BUILD_SYSTEM="auto"
    OIU_BUILD_DIR="."
    OIU_BUILD_BINARY=""
    OIU_BUILD_CUSTOM=""
    OIU_BUILD_MAKE_FLAGS="-j$(nproc 2>/dev/null || echo 2)"
    OIU_BUILD_CLEAN_CMD=""
    OIU_BUILD_CMAKE_DIR="build"
    OIU_BUILD_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release"
    OIU_BUILD_DOTNET_CONFIG="Release"
    OIU_BUILD_PYTHON_REQS="requirements.txt"

    # Compiler defaults per OS
    case "$OIU_OS" in
        macos|freebsd|openbsd|netbsd|dragonfly) OIU_BUILD_CXX="clang++" ; OIU_BUILD_CC="clang" ;;
        *) OIU_BUILD_CXX="g++" ; OIU_BUILD_CC="gcc" ;;
    esac
    OIU_BUILD_FLAGS_COMMON="-O2 -Wall"
    OIU_BUILD_FLAGS_DEBUG="-g -O0 -DDEBUG"
    OIU_BUILD_FLAGS_PLATFORM=""

    # macOS Apple Silicon / Homebrew paths
    if [[ "$OIU_OS" == "macos" ]] && command -v brew &>/dev/null; then
        local brew_prefix
        brew_prefix="$(brew --prefix 2>/dev/null)"
        OIU_BUILD_FLAGS_PLATFORM="-I${brew_prefix}/include -L${brew_prefix}/lib"
        if [[ "$OIU_HW_WEIRD" == "apple_silicon" ]]; then
            OIU_BUILD_FLAGS_PLATFORM+=" -I${brew_prefix}/opt/ncurses/include -L${brew_prefix}/opt/ncurses/lib"
        fi
    fi

    # FreeBSD: headers in /usr/local
    if [[ "$OIU_OS" == "freebsd" ]]; then
        OIU_BUILD_FLAGS_PLATFORM="-I/usr/local/include -L/usr/local/lib"
    fi

    [[ ! -f "$conf" ]] && return 0   # no builder.conf is fine — defaults apply

    # Parse conf — simple key.subkey = value format
    while IFS= read -r line; do
        line="${line%%#*}"   # strip comments
        line="${line//[$'\t']/ }"
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" ]] && continue

        local key val
        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"   # rtrim key
        val="${val#"${val%%[![:space:]]*}"}"   # ltrim val

        case "$key" in
            build_system)       OIU_BUILD_SYSTEM="$val"          ;;
            build_dir)          OIU_BUILD_DIR="$val"             ;;
            binary_output)      OIU_BUILD_BINARY="$val"          ;;
            custom_build)       OIU_BUILD_CUSTOM="$val"          ;;
            make_flags)         OIU_BUILD_MAKE_FLAGS="$val"      ;;
            make_clean)         OIU_BUILD_CLEAN_CMD="$val"       ;;
            cmake_build_dir)    OIU_BUILD_CMAKE_DIR="$val"       ;;
            cmake_flags)        OIU_BUILD_CMAKE_FLAGS="$val"     ;;
            dotnet_config)      OIU_BUILD_DOTNET_CONFIG="$val"   ;;
            python_reqs)        OIU_BUILD_PYTHON_REQS="$val"     ;;
            "compiler.linux")   [[ "$OIU_OS" == "linux" ]] && { OIU_BUILD_CXX="$val"; OIU_BUILD_CC="${val/++/}"; OIU_BUILD_CC="${OIU_BUILD_CC/clang+/clang}"; } ;;
            "compiler.macos")   [[ "$OIU_OS" == "macos" ]] && { OIU_BUILD_CXX="$val"; OIU_BUILD_CC="${val/clang++/clang}"; } ;;
            "compiler.freebsd") [[ "$OIU_OS" == "freebsd" ]] && { OIU_BUILD_CXX="$val"; } ;;
            "compiler.openbsd") [[ "$OIU_OS" == "openbsd" ]] && { OIU_BUILD_CXX="$val"; } ;;
            "compiler.netbsd")  [[ "$OIU_OS" == "netbsd"  ]] && { OIU_BUILD_CXX="$val"; } ;;
            "flags.common")     OIU_BUILD_FLAGS_COMMON="$val"    ;;
            "flags.debug")      OIU_BUILD_FLAGS_DEBUG="$val"     ;;
            "flags.linux")      [[ "$OIU_OS" == "linux" || "$OIU_OS" == "wsl" ]] && OIU_BUILD_FLAGS_PLATFORM="$val" ;;
            "flags.macos")      [[ "$OIU_OS" == "macos" ]] && OIU_BUILD_FLAGS_PLATFORM+=" $val" ;;
            "flags.freebsd")    [[ "$OIU_OS" == "freebsd" ]] && OIU_BUILD_FLAGS_PLATFORM+=" $val" ;;
        esac
    done < "$conf"

    export OIU_BUILD_SYSTEM OIU_BUILD_DIR OIU_BUILD_BINARY OIU_BUILD_CUSTOM
    export OIU_BUILD_CXX OIU_BUILD_CC OIU_BUILD_FLAGS_COMMON OIU_BUILD_FLAGS_DEBUG OIU_BUILD_FLAGS_PLATFORM
    export OIU_BUILD_MAKE_FLAGS OIU_BUILD_CLEAN_CMD
    export OIU_BUILD_CMAKE_DIR OIU_BUILD_CMAKE_FLAGS
    export OIU_BUILD_DOTNET_CONFIG OIU_BUILD_PYTHON_REQS
}

# ─── Auto-detect build system if not set ──────────────────────────────────────
oiu_builder_detect_system() {
    [[ "$OIU_BUILD_SYSTEM" != "auto" ]] && return 0

    if   [[ -f "CMakeLists.txt" ]];  then OIU_BUILD_SYSTEM="cmake"
    elif [[ -f "Makefile" ]];        then OIU_BUILD_SYSTEM="make"
    elif [[ -f "meson.build" ]];     then OIU_BUILD_SYSTEM="meson"
    elif [[ -f "Cargo.toml" ]];      then OIU_BUILD_SYSTEM="cargo"
    elif [[ -f "go.mod" ]];          then OIU_BUILD_SYSTEM="go"
    elif [[ -f "setup.py" ]] || [[ -f "pyproject.toml" ]]; then OIU_BUILD_SYSTEM="python"
    elif [[ -f "*.csproj" ]] || [[ -f "*.sln" ]]; then OIU_BUILD_SYSTEM="dotnet"
    else
        echo "  [!] Cannot detect build system. Set build_system in builder.conf" >&2
        return 1
    fi

    echo "  → Detected build system: $OIU_BUILD_SYSTEM"
    export OIU_BUILD_SYSTEM
}

# ─── Clean ────────────────────────────────────────────────────────────────────
oiu_builder_clean() {
    echo "  → Cleaning build artifacts..."
    if [[ -n "$OIU_BUILD_CUSTOM" ]]; then
        return 0   # custom build handles its own clean
    fi

    case "$OIU_BUILD_SYSTEM" in
        make)
            local clean_cmd="${OIU_BUILD_CLEAN_CMD:-$OIU_MAKE clean}"
            $clean_cmd 2>/dev/null || true
            ;;
        cmake)
            rm -rf "$OIU_BUILD_CMAKE_DIR" 2>/dev/null || true
            ;;
        cargo)
            cargo clean 2>/dev/null || true
            ;;
        meson)
            rm -rf build 2>/dev/null || true
            ;;
        python|dotnet)
            true   # nothing to clean for these
            ;;
    esac
    echo "  ✓ Clean complete"
}

# ─── Build ────────────────────────────────────────────────────────────────────
oiu_builder_build() {
    local debug="${1:-}"   # pass "debug" for debug build

    echo "  → Building with: $OIU_BUILD_SYSTEM"

    # If custom build command, just run it
    if [[ -n "$OIU_BUILD_CUSTOM" ]]; then
        echo "  → Custom build: $OIU_BUILD_CUSTOM"
        eval "$OIU_BUILD_CUSTOM" || { echo "  ✗ Custom build failed" >&2; return 1; }
        echo "  ✓ Custom build complete"
        return 0
    fi

    local flags="$OIU_BUILD_FLAGS_COMMON $OIU_BUILD_FLAGS_PLATFORM"
    [[ "$debug" == "debug" ]] && flags="$OIU_BUILD_FLAGS_DEBUG $OIU_BUILD_FLAGS_PLATFORM"

    case "$OIU_BUILD_SYSTEM" in
        # ── make ──────────────────────────────────────────────────────────────
        make)
            local make_cmd="$OIU_MAKE"
            # Export compiler vars so Makefile can pick them up
            export CXX="$OIU_BUILD_CXX"
            export CC="$OIU_BUILD_CC"
            export CXXFLAGS="$flags"
            export CFLAGS="$flags"

            # macOS: export brew ncurses paths for pkg-config
            if [[ "$OIU_OS" == "macos" ]] && command -v brew &>/dev/null; then
                local bp; bp="$(brew --prefix)"
                export PKG_CONFIG_PATH="$bp/opt/ncurses/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
                export LDFLAGS="-L$bp/opt/ncurses/lib ${LDFLAGS:-}"
                export CPPFLAGS="-I$bp/opt/ncurses/include ${CPPFLAGS:-}"
            fi

            $make_cmd $OIU_BUILD_MAKE_FLAGS || { echo "  ✗ make failed" >&2; return 1; }
            ;;

        # ── cmake ─────────────────────────────────────────────────────────────
        cmake)
            command -v cmake &>/dev/null || { echo "  ✗ cmake not found" >&2; return 1; }
            mkdir -p "$OIU_BUILD_CMAKE_DIR"
            cmake -S . -B "$OIU_BUILD_CMAKE_DIR" \
                $OIU_BUILD_CMAKE_FLAGS \
                -DCMAKE_C_COMPILER="$OIU_BUILD_CC" \
                -DCMAKE_CXX_COMPILER="$OIU_BUILD_CXX" \
                || { echo "  ✗ cmake configure failed" >&2; return 1; }
            cmake --build "$OIU_BUILD_CMAKE_DIR" -- $OIU_BUILD_MAKE_FLAGS \
                || { echo "  ✗ cmake build failed" >&2; return 1; }
            ;;

        # ── meson ─────────────────────────────────────────────────────────────
        meson)
            command -v meson &>/dev/null || { echo "  ✗ meson not found" >&2; return 1; }
            meson setup build --wipe 2>/dev/null || meson setup build
            meson compile -C build || { echo "  ✗ meson build failed" >&2; return 1; }
            ;;

        # ── cargo (Rust) ──────────────────────────────────────────────────────
        cargo)
            command -v cargo &>/dev/null || { echo "  ✗ cargo not found. Install Rust: https://rustup.rs" >&2; return 1; }
            if [[ "$debug" == "debug" ]]; then
                cargo build || { echo "  ✗ cargo build failed" >&2; return 1; }
            else
                cargo build --release || { echo "  ✗ cargo build failed" >&2; return 1; }
            fi
            ;;

        # ── go ────────────────────────────────────────────────────────────────
        go)
            command -v go &>/dev/null || { echo "  ✗ go not found" >&2; return 1; }
            local out="${OIU_BUILD_BINARY:-$(basename "$PWD")}"
            go build -o "$out" ./... || { echo "  ✗ go build failed" >&2; return 1; }
            ;;

        # ── C# / dotnet ───────────────────────────────────────────────────────
        dotnet)
            if command -v dotnet &>/dev/null; then
                dotnet build --configuration "$OIU_BUILD_DOTNET_CONFIG" \
                    || { echo "  ✗ dotnet build failed" >&2; return 1; }
                dotnet publish --configuration "$OIU_BUILD_DOTNET_CONFIG" \
                    --output ./publish \
                    || { echo "  ✗ dotnet publish failed" >&2; return 1; }
            elif command -v mono &>/dev/null && command -v mcs &>/dev/null; then
                # Mono fallback
                local srcs
                srcs=$(find . -name "*.cs" -not -path "*/obj/*" | tr '\n' ' ')
                local out="${OIU_BUILD_BINARY:-app}.exe"
                mcs -out:"$out" $srcs || { echo "  ✗ mono mcs build failed" >&2; return 1; }
            else
                echo "  ✗ No .NET runtime found (dotnet or mono)" >&2; return 1
            fi
            ;;

        # ── Python ────────────────────────────────────────────────────────────
        python)
            # Python apps don't "build" — but we set up a venv and install deps
            echo "  → Python app — setting up environment..."
            if [[ -n "$OIU_PYTHON" ]]; then
                # Create venv if it doesn't exist
                if [[ ! -d ".venv" ]]; then
                    $OIU_PYTHON -m venv .venv \
                        || { echo "  ✗ Failed to create virtualenv" >&2; return 1; }
                    echo "  ✓ Virtual environment created"
                fi
                # Install requirements
                local reqs="${OIU_BUILD_PYTHON_REQS:-requirements.txt}"
                if [[ -f "$reqs" ]]; then
                    .venv/bin/pip install -q -r "$reqs" \
                        || { echo "  ✗ pip install failed" >&2; return 1; }
                    echo "  ✓ Python dependencies installed"
                fi
            else
                echo "  ✗ Python not found" >&2; return 1
            fi
            ;;

        *)
            echo "  ✗ Unknown build system: $OIU_BUILD_SYSTEM" >&2
            return 1
            ;;
    esac

    echo "  ✓ Build complete"
    return 0
}

# ─── Locate the built binary ──────────────────────────────────────────────────
# Returns path to binary, or empty if not found
oiu_builder_find_binary() {
    local name="${OIU_BUILD_BINARY:-$(basename "$PWD")}"

    # Common output locations
    local candidates=(
        "./$name"
        "./build/$name"
        "./publish/$name"
        "./target/release/$name"
        "./target/debug/$name"
        "./$OIU_BUILD_CMAKE_DIR/$name"
    )

    for c in "${candidates[@]}"; do
        if [[ -f "$c" && -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done

    # Python: binary is the entry script
    if [[ "$OIU_BUILD_SYSTEM" == "python" ]]; then
        for ext in "" ".py"; do
            [[ -f "./${name}${ext}" ]] && echo "./${name}${ext}" && return 0
        done
    fi

    return 1
}

export -f oiu_builder_load_conf oiu_builder_detect_system
export -f oiu_builder_clean oiu_builder_build oiu_builder_find_binary
