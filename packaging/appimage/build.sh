#!/bin/sh
# Build the blip AppImage from a release tree. Usage:
#   packaging/appimage/build.sh <version> <blip-linux-binary> <out-dir>
# The version is informational (it tags the file name); the binary is
# dist/blip-linux from the release build. Downloads appimagetool on first
# use (pinned version below); building needs squashfs tools, running the
# result needs FUSE. Layout mirrors the .deb: the binary on PATH inside
# the image, the prelude and programs under usr/share/blip, docs under
# usr/share/doc/blip. AppRun is a symlink to the binary, so resource_path
# resolves the prelude relative to the mount point.
set -e
VERSION="$1"
BIN="$2"
OUTDIR="$3"
if [ -z "$VERSION" ] || [ -z "$BIN" ] || [ -z "$OUTDIR" ]; then
  echo "usage: packaging/appimage/build.sh <version> <blip-linux-binary> <out-dir>" >&2
  exit 2
fi
case "$VERSION" in
  [0-9A-Za-z]* ) ;;
  *) echo "blip appimage: version must start with an alphanumeric, got '$VERSION'" >&2; exit 2 ;;
esac
if [ ! -x "$BIN" ]; then
  echo "blip appimage: no binary at '$BIN'" >&2
  exit 2
fi
case "$OUTDIR" in
  /*) OUTABS="$OUTDIR" ;;
  *) OUTABS="$(pwd)/$OUTDIR" ;;
esac
mkdir -p "$OUTABS"

APPIMAGETOOL_VERSION=1.9.1
APPIMAGETOOL="appimagetool-x86_64.AppImage"
if ! command -v "$APPIMAGETOOL" >/dev/null 2>&1 && [ ! -x "./$APPIMAGETOOL" ]; then
  echo "blip appimage: fetching appimagetool ${APPIMAGETOOL_VERSION}..."
  curl -fsSL -o "$APPIMAGETOOL" "https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}/${APPIMAGETOOL}"
  chmod +x "$APPIMAGETOOL"
fi
if [ -x "./$APPIMAGETOOL" ]; then
  TOOL="./$APPIMAGETOOL"
else
  TOOL="$APPIMAGETOOL"
fi

ROOT="$(pwd)/.appimage-tree"
rm -rf "$ROOT"
mkdir -p "$ROOT/usr/bin" "$ROOT/usr/share/blip/lib" "$ROOT/usr/share/blip/programs" "$ROOT/usr/share/doc/blip" "$ROOT/usr/share/icons/hicolor/scalable/apps"
cp "$BIN" "$ROOT/usr/bin/blip"
chmod 755 "$ROOT/usr/bin/blip"
ln -sf usr/bin/blip "$ROOT/AppRun"
cp lib/*.blip "$ROOT/usr/share/blip/lib/"
cp programs/*.blip "$ROOT/usr/share/blip/programs/"
cp packaging/copyright "$ROOT/usr/share/doc/blip/copyright"
cp README.md "$ROOT/usr/share/doc/blip/README.md"
cp site/assets/logo.svg "$ROOT/usr/share/icons/hicolor/scalable/apps/blip.svg"
cp site/assets/logo.svg "$ROOT/blip.svg"
ln -sf blip.svg "$ROOT/.DirIcon"
cp packaging/appimage/blip.desktop "$ROOT/blip.desktop"
chmod 644 "$ROOT"/usr/share/blip/lib/*.blip "$ROOT"/usr/share/blip/programs/*.blip "$ROOT"/usr/share/doc/blip/copyright "$ROOT"/usr/share/doc/blip/README.md "$ROOT"/blip.desktop "$ROOT"/blip.svg

ARTIFACT="blip-${VERSION}-x86_64.AppImage"
"$TOOL" --comp zstd "$ROOT" "$OUTABS/$ARTIFACT" 2>&1 | tail -n 3
rm -rf "$ROOT"
echo "blip appimage: wrote $OUTABS/$ARTIFACT"
