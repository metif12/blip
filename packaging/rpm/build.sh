#!/bin/sh
# Build the blip .rpm from a release tree. Usage:
#   packaging/rpm/build.sh <version> <blip-linux-binary> <out.rpm>
# The version is the tag without the leading v (2.0.0, not v2.0.0); the
# binary is dist/blip-linux from the release build. Requires rpm-build.
# Layout mirrors the .deb: the binary on PATH, the prelude and programs
# under /usr/share/blip (see main.v resource_path), docs under
# /usr/share/doc/blip.
set -e
VERSION="$1"
BIN="$2"
OUT="$3"
if [ -z "$VERSION" ] || [ -z "$BIN" ] || [ -z "$OUT" ]; then
  echo "usage: packaging/rpm/build.sh <version> <blip-linux-binary> <out.rpm>" >&2
  exit 2
fi
case "$VERSION" in
  [0-9]* ) ;;
  *) echo "blip rpm: version must start with a digit, got '$VERSION'" >&2; exit 2 ;;
esac
if [ ! -x "$BIN" ]; then
  echo "blip rpm: no binary at '$BIN'" >&2
  exit 2
fi

# rpmbuild wants its own tree; the spec stages from an absolute path so
# the build works from any directory and leaves the repo untouched.
TOP="$(pwd)/.rpm-tree"
rm -rf "$TOP"
mkdir -p "$TOP/SPECS" "$TOP/stage/bin" "$TOP/stage/lib" "$TOP/stage/programs" "$TOP/stage/doc"
cp "$BIN" "$TOP/stage/bin/blip"
chmod 755 "$TOP/stage/bin/blip"
cp lib/*.blip "$TOP/stage/lib/"
cp programs/*.blip "$TOP/stage/programs/"
cp packaging/copyright "$TOP/stage/doc/copyright"
cp README.md "$TOP/stage/doc/README.md"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$(date -u +'%a %b %d %Y')/g" \
  packaging/rpm/blip.spec.in > "$TOP/SPECS/blip.spec"

rpmbuild -bb --define "_topdir $TOP" --define "stagedir $TOP/stage" \
  "$TOP/SPECS/blip.spec"
mv "$TOP"/RPMS/x86_64/blip-*.rpm "$OUT"
rm -rf "$TOP"
echo "blip rpm: wrote $OUT"
rpm -qlp "$OUT"
