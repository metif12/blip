#!/usr/bin/env bash
set -euo pipefail

# blip builds against stock V 0.5.2: the official release archive, not a
# master build. A master build reports the same "V 0.5.2" version string for
# different commits while resolving project modules differently, so "whatever
# vlang/v master is this morning" is how an install works on Friday and fails
# on Monday. The release archive is that compiler, byte for byte, on every
# machine -- no source build, no vc bootstrap.
#
# Keep the version below in sync with .github/workflows/ci.yml.
V_VERSION=0.5.2

BLIP_DIR="${BLIP_INSTALL_DIR:-$HOME/.blip}"
V_DIR="${BLIP_V_DIR:-$HOME/.blip-v}"
REPO="https://github.com/metif12/blip.git"

echo "==> Installing blip to $BLIP_DIR"

if [ ! -d "$BLIP_DIR" ]; then
    git clone "$REPO" "$BLIP_DIR"
fi

cd "$BLIP_DIR"
git pull --ff-only

# The bootstrap compiles vc/v.c with a C compiler. Saying so up front beats a
# bare "failed to find executable cc" three minutes in.
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "==> ERROR: no C compiler found."
    echo "    blip builds itself and V with cc/gcc. Install one, e.g."
    echo "      Debian/Ubuntu:  sudo apt install build-essential"
    echo "      Fedora:         sudo dnf install gcc"
    echo "      macOS:          xcode-select --install"
    exit 1
fi

# V links its own binary against Boehm GC. Without libgc-dev the build dies
# with "Boehm GC library was not found" three minutes in.
if ! (echo '#include <gc.h>' | cc -x c - -o /dev/null 2>/dev/null); then
    echo "==> ERROR: Boehm GC (libgc) development files not found."
    echo "    Debian/Ubuntu:  sudo apt install libgc-dev"
    echo "    Fedora:         sudo dnf install gc-devel"
    echo "    Alpine:         apk add gc-dev"
    echo "    macOS:          brew install bdw-gc"
    exit 1
fi

case "$(uname -s)-$(uname -m)" in
    Linux-*)     V_ASSET="v_linux.zip" ;;
    Darwin-arm64)  V_ASSET="v_macos_arm64.zip" ;;
    Darwin-*)    V_ASSET="v_macos_x86_64.zip" ;;
    *) echo "==> ERROR: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

setup_v() {
    if [ -x "$V_DIR/v" ] && [ -f "$V_DIR/.blip-version" ] \
        && [ "$(cat "$V_DIR/.blip-version")" = "$V_VERSION" ]; then
        return 0
    fi
    echo "==> V $V_VERSION not found. Downloading the official release..."
    rm -rf "$V_DIR"
    mkdir -p "$V_DIR"
    tmp="$(mktemp -d)"
    curl -sSL -o "$tmp/v.zip" "https://github.com/vlang/v/releases/download/$V_VERSION/$V_ASSET"
    unzip -q "$tmp/v.zip" -d "$tmp"
    mv "$tmp/v"/* "$V_DIR/"
    rm -rf "$tmp"
    if [ ! -x "$V_DIR/v" ]; then
        echo "==> ERROR: V download finished but produced no $V_DIR/v binary" >&2
        exit 1
    fi
    printf '%s' "$V_VERSION" > "$V_DIR/.blip-version"
}

setup_v
export PATH="$V_DIR:$PATH"

# From the repo root, so the relative `vlib` in -path resolves: it points the
# compiler at this repo's own vlib/ for `import blip.*`, with the standard
# library behind it.
"$V_DIR/v" -cc gcc -path 'vlib|@vlib' -o "$BLIP_DIR/blip" main.v

echo "==> blip installed to $BLIP_DIR/blip"
echo "==> Add it to your PATH:  export PATH=\"$BLIP_DIR:\$PATH\""
echo "==> Try it:               blip repl"
