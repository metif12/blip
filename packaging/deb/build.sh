#!/bin/sh
# Build the blip .deb from a release tree. Usage:
#   packaging/deb/build.sh <version> <blip-linux-binary> <out.deb>
# The version is the tag without the leading v (2.0.0, not v2.0.0); the
# binary is dist/blip-linux from the release build. Requires dpkg-deb.
# Layout follows the lookup the binary already does: the prelude lives
# under /usr/share/blip (see main.v resource_path), the binary on PATH.
set -e
VERSION="$1"
BIN="$2"
OUT="$3"
if [ -z "$VERSION" ] || [ -z "$BIN" ] || [ -z "$OUT" ]; then
  echo "usage: packaging/deb/build.sh <version> <blip-linux-binary> <out.deb>" >&2
  exit 2
fi
case "$VERSION" in
  [0-9]* ) ;;
  *) echo "blip deb: version must start with a digit, got '$VERSION'" >&2; exit 2 ;;
esac
if [ ! -x "$BIN" ]; then
  echo "blip deb: no binary at '$BIN'" >&2
  exit 2
fi

ROOT="$(pwd)/.deb-tree"
rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/bin" "$ROOT/usr/share/blip/lib" \
  "$ROOT/usr/share/blip/programs" "$ROOT/usr/share/doc/blip"

sed "s/@VERSION@/$VERSION/" packaging/deb/control.in > "$ROOT/DEBIAN/control"
cp "$BIN" "$ROOT/usr/bin/blip"
chmod 755 "$ROOT/usr/bin/blip"
cp lib/*.blip "$ROOT/usr/share/blip/lib/"
cp programs/*.blip "$ROOT/usr/share/blip/programs/"
cp packaging/copyright "$ROOT/usr/share/doc/blip/copyright"
cp README.md "$ROOT/usr/share/doc/blip/README.md"
chmod 644 "$ROOT/DEBIAN/control" "$ROOT/usr/share/blip/lib/"*.blip \
  "$ROOT/usr/share/blip/programs/"*.blip \
  "$ROOT/usr/share/doc/blip/copyright" "$ROOT/usr/share/doc/blip/README.md"

SIZE_KB=$(du -sk "$ROOT/usr" | cut -f1)
echo "Installed-Size: $SIZE_KB" >> "$ROOT/DEBIAN/control"

dpkg-deb --root-owner-group --build "$ROOT" "$OUT"
dpkg-deb --info "$OUT" | head -n 12
rm -rf "$ROOT"
echo "blip deb: wrote $OUT"
