#!/bin/sh
# Assemble an ipk from pkg/ and a binary built by build.sh.
# Usage: ./mkipk.sh <tag> <target-id> [pkgrel]
# Output: out/cloudflared_<tag>-r<pkgrel>_<ipk-arch>.ipk
set -eu

TAG=${1:?usage: mkipk.sh <tag> <target-id> [pkgrel]}
ID=${2:?usage: mkipk.sh <tag> <target-id> [pkgrel]}
PKGREL=${3:-1}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
BIN=$OUT/cloudflared-$ID
LICENSE=$HERE/work/cloudflared-$TAG/LICENSE

ARCH=$(awk -v id="$ID" '$1 == id { print $4 }' "$HERE/targets")
[ -n "$ARCH" ] || { echo "unknown target: $ID" >&2; exit 1; }
[ -f "$BIN" ] || { echo "missing $BIN, run build.sh first" >&2; exit 1; }
[ -f "$LICENSE" ] || { echo "missing $LICENSE, run build.sh first" >&2; exit 1; }

VERSION=$TAG-r$PKGREL
IPK=$OUT/cloudflared_${VERSION}_$ARCH.ipk
# Fixed timestamp so rebuilds of the same inputs are byte-identical.
EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$HERE/work/cloudflared-$TAG" log -1 --format=%ct)}
case $EPOCH in '' | *[!0-9]*) echo "no timestamp: set SOURCE_DATE_EPOCH or install git" >&2; exit 1 ;; esac

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/control" "$STAGE/data"

# data: files land under the opkg dest root (/usr/local on RutOS, / on OpenWrt).
cp -R "$HERE/pkg/data/." "$STAGE/data/"
install -d "$STAGE/data/usr/bin" "$STAGE/data/usr/share/licenses/cloudflared"
cp "$BIN" "$STAGE/data/usr/bin/cloudflared"
cp "$LICENSE" "$STAGE/data/usr/share/licenses/cloudflared/LICENSE"
find "$STAGE/data" -type d -exec chmod 0755 {} +
find "$STAGE/data" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/data/usr/bin/cloudflared" "$STAGE/data/etc/init.d/cloudflared"
chmod 0600 "$STAGE/data/etc/config/cloudflared"

# control
SIZE=$(du -sk "$STAGE/data" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@ARCH@/$ARCH/" -e "s/@SIZE@/$SIZE/" \
	"$HERE/pkg/control/control.in" > "$STAGE/control/control"
for f in conffiles postinst prerm; do cp "$HERE/pkg/control/$f" "$STAGE/control/"; done
chmod 0644 "$STAGE/control/control" "$STAGE/control/conffiles"
chmod 0755 "$STAGE/control/postinst" "$STAGE/control/prerm"
echo 2.0 > "$STAGE/debian-binary"

# tar with root ownership and fixed mtimes; GNU tar in CI, bsdtar on macOS.
find "$STAGE" -exec touch -h -d "@$EPOCH" {} + 2>/dev/null ||
	TZ=UTC find "$STAGE" -exec touch -h -t "$(TZ=UTC date -r "$EPOCH" +%Y%m%d%H%M.%S)" {} +
if tar --version 2>/dev/null | grep -q GNU; then
	TAR_OPTS="--format=ustar --owner=root:0 --group=root:0 --sort=name"
else
	TAR_OPTS="--format=ustar --uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata"
fi
mktar() { # dir -> dir.tar.gz
	# shellcheck disable=SC2086
	(cd "$STAGE/$1" && tar $TAR_OPTS -cf - .) | gzip -9n > "$STAGE/$1.tar.gz"
}
mktar control
mktar data

# Outer ar archive (Debian/opkg format), written by hand so it is the same on every host.
ar_member() { # file
	size=$(wc -c < "$STAGE/$1" | tr -d ' ')
	printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$1" "$EPOCH" 0 0 100644 "$size"
	cat "$STAGE/$1"
	[ $((size % 2)) -eq 0 ] || printf '\n'
}
{
	printf '!<arch>\n'
	ar_member debian-binary
	ar_member control.tar.gz
	ar_member data.tar.gz
} > "$IPK"
echo "$IPK"
