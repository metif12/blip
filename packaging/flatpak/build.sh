#!/bin/sh
# Build the blip Flatpak from a release tree. Usage:
#   packaging/flatpak/build.sh <version> <blip-linux-binary> <out-dir>
# The version names the output file only (Flatpak versions ride the
# branch); the binary is dist/blip-linux from the release build.
# Needs flatpak-builder plus the org.freedesktop Platform/Sdk 25.08.
# Runs `flatpak-builder` in destructive mode (no separate build VM).
# Layout mirrors the .deb: the binary on PATH inside the sandbox
# (/usr/bin/blip), the prelude under /usr/share/blip, docs under
# /usr/share/doc/blip -- mapped to /app equivalents at build time.
set -e
VERSION="$1"
BIN="$2"
OUTDIR="$3"
if [ -z "$VERSION" ] || [ -z "$BIN" ] || [ -z "$OUTDIR" ]; then
  echo "usage: packaging/flatpak/build.sh <version> <blip-linux-binary> <out-dir>" >&2
  exit 2
fi
case "$VERSION" in
  [0-9A-Za-z]* ) ;;
  *) echo "blip flatpak: version must start with an alphanumeric, got '$VERSION'" >&2; exit 2 ;;
esac
if [ ! -x "$BIN" ]; then
  echo "blip flatpak: no binary at '$BIN'" >&2
  exit 2
fi
case "$OUTDIR" in
  /*) OUTABS="$OUTDIR" ;;
  *) OUTABS="$(pwd)/$OUTDIR" ;;
esac
mkdir -p "$OUTABS"

ROOT="$(pwd)/.flatpak-build"
rm -rf "$ROOT"
mkdir -p "$ROOT/stage" "$ROOT/repo"
if [ ! -d "$ROOT/repo/objects" ] && command -v ostree >/dev/null 2>&1; then
  ostree init --repo="$ROOT/repo" --mode=bare-user
fi
cp packaging/flatpak/blip.yaml "$ROOT/stage/blip.yaml"
cp "$BIN" "$ROOT/stage/blip"
chmod 755 "$ROOT/stage/blip"
mkdir -p "$ROOT/stage/lib" "$ROOT/stage/programs"
cp lib/*.blip "$ROOT/stage/lib/"
cp programs/*.blip "$ROOT/stage/programs/"
cp README.md "$ROOT/stage/README.md"
(cd "$ROOT/stage" && flatpak-builder --force-clean --repo="$ROOT/repo" builddir blip.yaml 2>&1 | tail -n 3)
ARTIFACT="blip_${VERSION}_x86_64.flatpak"
flatpak build-bundle "$ROOT/repo" "$OUTABS/$ARTIFACT" io.github.metif12.blip
rm -rf "$ROOT"
echo "blip flatpak: wrote $OUTABS/$ARTIFACT"
