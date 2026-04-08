# Installing ytcui

ytcui uses **OIU (OneInstallUtility)** — one command handles everything.

## Install

```bash
git clone https://github.com/YOUR_USER/ytcui
cd ytcui
./oiu/oiu install
```

That's it. OIU detects your OS, installs dependencies, builds from source,
and places the binary in `/usr/local/bin` (or `~/.local/bin` if no sudo).

## Update

```bash
ytcui --upgrade        # from anywhere, once installed
# or
./oiu/oiu update       # from the repo directory
```

## Uninstall

```bash
./oiu/oiu uninstall
```

Removes the binary, desktop entry, and all OIU-tracked files. Optionally
keeps your config and library (`~/.config/ytcui`, `~/.local/share/ytcui`).

## Other commands

```bash
./oiu/oiu status       # installed version, update availability
./oiu/oiu repair       # rebuild binary only, keep all user data
./oiu/oiu reinstall    # full clean reinstall
./oiu/oiu info         # system detection details
./oiu/oiu help         # full usage
```

## Supported platforms

Linux (apt / pacman / dnf / zypper / apk / emerge / xbps),
macOS (Homebrew / MacPorts), FreeBSD, OpenBSD, NetBSD.
x86\_64 and arm64.
