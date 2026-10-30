#!/usr/bin/env bash
set -euo pipefail

# blip builds against ONE compiler: the commit pinned in
# .github/workflows/ci.yml. Building against "whatever vlang/v master is this
# morning" is how an install works on Friday and fails on Monday -- 1123
# commits upstream changed the checker out from under vlib/blip. So V and its
# vc bootstrap are pinned to exactly the pair CI builds, and the same two
# commits appear in both install scripts and CI.
#
# Keep these two lines in sync with ci.yml.
V_COMMIT=74be97a2d7bd1fce4150abc749a2e64b21d9d082
VC_COMMIT=0027130e9850c9946fa2c21e9004f13d8e593595

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

setup_v() {
    if [ -x "$V_DIR/v" ] && [ -f "$V_DIR/.blip-commit" ] \
        && [ "$(cat "$V_DIR/.blip-commit")" = "$V_COMMIT" ]; then
        return 0
    fi
    echo "==> V not found (or not the pinned build). Building V $V_COMMIT..."
    echo "    This compiles V from source once and takes a few minutes."
    rm -rf "$V_DIR"
    git init -q "$V_DIR"
    cd "$V_DIR"
    git remote add origin https://github.com/vlang/v.git
    git fetch -q --depth 1 origin "$V_COMMIT"
    git checkout -q FETCH_HEAD
    # vc is the C source the bootstrap compiles into `v`, and it is a SEPARATE
    # repository that V's own Makefile clones at HEAD -- UNPINNED. A vc
    # snapshot from a newer V can reject the pinned tree's own vlib, so vc is
    # cloned at its own pin -- the same reasoning CI records in ci.yml.
    git clone -q https://github.com/vlang/vc vc
    git -C vc fetch -q --depth 1 origin "$VC_COMMIT"
    git -C vc checkout -q FETCH_HEAD
    make -f Makefile v
    if [ ! -x ./v ]; then
        echo "==> ERROR: V build finished but produced no ./v binary" >&2
        exit 1
    fi
    printf '%s' "$V_COMMIT" > .blip-commit
    cd "$BLIP_DIR"
}

setup_v
export PATH="$V_DIR:$PATH"

"$V_DIR/v" -cc gcc -o "$BLIP_DIR/blip" blip.v

echo "==> blip installed to $BLIP_DIR/blip"
echo "==> Add it to your PATH:  export PATH=\"$BLIP_DIR:\$PATH\""
echo "==> Try it:               blip repl"
