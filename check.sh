#!/bin/sh
# Smoke-test built packages: layout, modes, arch, and (if qemu-user is present) the binary runs.
# Usage: ./check.sh <tag> out/*.ipk
set -eu

TAG=${1:?usage: check.sh <tag> <ipk...>}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
fail() { echo "FAIL $IPK: $*" >&2; exit 1; }

for IPK in "$@"; do
	T=$(mktemp -d)
	abs=$(cd "$(dirname "$IPK")" && pwd)/$(basename "$IPK")
	(cd "$T" && ar x "$abs") || fail "not an ar archive"
	[ "$(cat "$T/debian-binary")" = 2.0 ] || fail "bad debian-binary"
	mkdir "$T/c" "$T/d"
	tar -xzf "$T/control.tar.gz" -C "$T/c"
	tar -tvzf "$T/data.tar.gz" > "$T/data.list"

	arch=$(sed -n 's/^Architecture: //p' "$T/c/control")
	id=$(awk -v a="$arch" '$4 == a { print $1 }' "$HERE/targets")
	[ -n "$id" ] || fail "Architecture '$arch' is not in targets"
	grep -qx "Version: $TAG-r[0-9]*" "$T/c/control" || fail "Version does not match $TAG"
	grep -qx /etc/config/cloudflared "$T/c/conffiles" || fail "config not in conffiles"
	for s in postinst prerm; do
		[ -x "$T/c/$s" ] || fail "$s not executable"
	done

	for want in \
		'-rwxr-xr-x root/root ./usr/bin/cloudflared' \
		'-rwxr-xr-x root/root ./etc/init.d/cloudflared' \
		'-rw------- root/root ./etc/config/cloudflared' \
		'-rw-r--r-- root/root ./lib/upgrade/keep.d/cloudflared' \
		'-rw-r--r-- root/root ./usr/share/licenses/cloudflared/LICENSE'; do
		mode=${want%% *}; rest=${want#* }; owner=${rest%% *}; path=${rest#* }
		awk -v m="$mode" -v p="$path" -v o="$owner" \
			'$1 == m && $NF == p && ($2 == o || ($3 == "root" && $4 == "root"))' \
			"$T/data.list" | grep -q . || fail "missing or wrong mode/owner: $want"
	done

	qemu=
	case $id in
	armv7) qemu="qemu-arm-static" ;;
	mipsle) qemu="qemu-mipsel-static" ;;
	esac
	if command -v "$qemu" >/dev/null 2>&1; then
		tar -xzf "$T/data.tar.gz" -C "$T/d" ./usr/bin/cloudflared
		"$qemu" "$T/d/usr/bin/cloudflared" --version | grep -q "version $TAG " ||
			fail "binary does not report version $TAG"
		echo "ok   $IPK (ran under $qemu)"
	else
		echo "ok   $IPK (layout only, $qemu not installed)"
	fi
	rm -rf "$T"
done
