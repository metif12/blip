#!/bin/sh
# Build the blip .snap from a release tree. Usage:
#   packaging/snap/build.sh <version> <blip-linux-binary> <out-dir>
# The version is the tag without the leading v (2.0.0, not v2.0.0); the
# binary is dist/blip-linux from the release build. Runs `snapcraft pack`
# in destructive mode (no LXD), so it works on CI runners and containers.
# Layout mirrors the .deb: the binary on PATH, the prelude and programs
# under usr/share/blip, docs under usr/share/doc/blip.
set -e
VERSION="$1"
BIN="$2"
OUTDIR="$3"
if [ -z "$VERSION" ] || [ -z "$BIN" ] || [ -z "$OUTDIR" ]; then
  echo "usage: packaging/snap/build.sh <version> <blip-linux-binary> <out-dir>" >&2
  exit 2
fi
case "$VERSION" in
  [0-9A-Za-z]* ) ;;
  *) echo "blip snap: version must start with an alphanumeric, got '$VERSION'" >&2; exit 2 ;;
esac
if [ ! -x "$BIN" ]; then
  echo "blip snap: no binary at '$BIN'" >&2
  exit 2
fi

ROOT="$(pwd)/.snap-build"
rm -rf "$ROOT"
mkdir -p "$ROOT/usr/bin" "$ROOT/usr/share/blip/lib" "$ROOT/usr/share/blip/programs" "$ROOT/usr/share/doc/blip" "$ROOT/snap"
case "$OUTDIR" in
  /*) OUTABS="$OUTDIR" ;;
  *) OUTABS="$(pwd)/$OUTDIR" ;;
esac
mkdir -p "$OUTABS"
cp "$BIN" "$ROOT/usr/bin/blip"
chmod 755 "$ROOT/usr/bin/blip"
cp lib/*.blip "$ROOT/usr/share/blip/lib/"
cp programs/*.blip "$ROOT/usr/share/blip/programs/"
cp packaging/copyright "$ROOT/usr/share/doc/blip/copyright"
cp README.md "$ROOT/usr/share/doc/blip/README.md"
chmod 644 "$ROOT"/usr/share/blip/lib/*.blip "$ROOT"/usr/share/blip/programs/*.blip "$ROOT"/usr/share/doc/blip/copyright "$ROOT"/usr/share/doc/blip/README.md
sed "s/@VERSION@/$VERSION/g" packaging/snap/snapcraft.yaml.in > "$ROOT/snap/snapcraft.yaml"
# snapcraft reads the project dir for `source: .` traversal
# and refuses to write packages outside it, so build in-tree
# and move the result out.
ARTIFACT="blip_${VERSION}_amd64.snap"
(cd "$ROOT" && snapcraft pack --destructive-mode --output "$ARTIFACT" 2>&1 | tail -n 5)
mv "$ROOT/$ARTIFACT" "$OUTABS/$ARTIFACT"
ls "$OUTABS"/blip_*.snap
rm -rf "$ROOT"
echo "blip snap: wrote $OUTABS/$ARTIFACT"
