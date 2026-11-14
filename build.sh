#!/bin/sh
# Cross-compile cloudflared from an unmodified upstream tag.
# Usage: ./build.sh <tag> [target-id...]   (default: every target in ./targets)
# Output: out/cloudflared-<target-id>
set -eu

TAG=${1:?usage: build.sh <tag> [target-id...]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/work/cloudflared-$TAG
OUT=$HERE/out
mkdir -p "$OUT" "$HERE/work"

if [ ! -d "$SRC/.git" ]; then
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
		https://github.com/cloudflare/cloudflared "$SRC"
fi

cd "$SRC"
# Build with exactly the Go version upstream pins, like upstream's Makefile.
if [ "$(go env GOTOOLCHAIN)" != local ]; then
	GOTOOLCHAIN=go$(go list -m -f '{{.GoVersion}}')
	export GOTOOLCHAIN
fi
BUILD_TIME=$(git log -1 --format=%cd --date=format-local:'%Y-%m-%d-%H:%M UTC')
LDFLAGS="-s -w -X main.Version=$TAG -X 'main.BuildTime=$BUILD_TIME' \
-X github.com/cloudflare/cloudflared/cmd/cloudflared/updater.BuiltForPackageManager=opkg"

grep -v '^#' "$HERE/targets" | while read -r id goarch variant _; do
	[ -n "$id" ] || continue
	if [ $# -gt 0 ]; then
		case " $* " in *" $id "*) ;; *) continue ;; esac
	fi
	echo "building $id ($goarch $variant)"
	env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" "$variant" GOFIPS140=off \
		go build -mod=readonly -trimpath -ldflags "$LDFLAGS" \
		-o "$OUT/cloudflared-$id" ./cmd/cloudflared
done
