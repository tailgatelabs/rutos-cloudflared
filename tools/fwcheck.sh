#!/bin/sh
# Read-only snapshot of cloudflared on a RutOS router, for before and after a firmware upgrade.
# Runs on the router (BusyBox ash). Changes nothing. Never prints the tunnel token.
#
# From your computer:
#   ssh <router> sh -s pre  < tools/fwcheck.sh > fwcheck-pre.txt
#   ssh <router> sh -s post < tools/fwcheck.sh > fwcheck-post.txt
#   diff fwcheck-pre.txt fwcheck-post.txt

LABEL=${1:-snapshot}
BIN=/usr/local/usr/bin/cloudflared
[ -x "$BIN" ] || [ ! -x /usr/bin/cloudflared ] || BIN=/usr/bin/cloudflared
INIT=/etc/init.d/cloudflared
CONF=/etc/config/cloudflared

section() { printf '\n## %s\n' "$1"; }
have() { [ -e "$1" ] && echo "present  $1" || echo "MISSING  $1"; }

echo "# cloudflared fwcheck: $LABEL"
echo "taken: $(date -u '+%Y-%m-%d %H:%M:%S UTC'), up $(cut -d. -f1 /proc/uptime)s"

section firmware
cat /etc/version 2>/dev/null || echo "no /etc/version"
uname -r

section package
opkg list-installed 2>/dev/null | grep '^cloudflared ' || echo "cloudflared package NOT installed"
opkg status cloudflared 2>/dev/null | grep -E '^(Version|Architecture|Status):'

section files
for f in "$BIN" "$INIT" "$CONF" /usr/local/lib/upgrade/keep.d/cloudflared \
	/usr/local/usr/share/licenses/cloudflared/LICENSE; do
	have "$f"
done
[ -e "$BIN" ] && sha256sum "$BIN" && "$BIN" --version 2>&1 | head -1
[ -e "$INIT" ] && sha256sum "$INIT"
[ -e "$CONF" ] && ls -l "$CONF"
# Leftovers such as a config copy opkg writes next to an existing one on reinstall.
for f in /etc/config/*cloudflared*; do [ -e "$f" ] && [ "$f" != "$CONF" ] && echo "extra    $(ls -l "$f")"; done

section config
if [ -e "$CONF" ]; then
	for o in enabled protocol loglevel; do
		echo "$o=$(uci -q get "cloudflared.main.$o")"
	done
	tok=$(uci -q get cloudflared.main.token)
	echo "token length=${#tok} (value not shown)"
	unset tok
else
	echo "no config"
fi

section service
links=
for f in /etc/rc.d/*cloudflared; do [ -e "$f" ] && links="$links ${f##*/}"; done
echo "boot links:${links:- none}"
pid=$(pidof cloudflared)
if [ -n "$pid" ]; then
	echo "running, pid $pid"
	grep -E '^VmRSS' "/proc/$pid/status"
else
	echo "NOT running"
fi
ubus call service list '{"name":"cloudflared"}' 2>/dev/null | grep -E '"(running|exit_code|term)"' | tr -d '\t'

section "tunnel log since boot"
logread -e cloudflared 2>/dev/null > /tmp/fwcheck.log
echo "registered connections: $(grep -c 'Registered tunnel connection' /tmp/fwcheck.log)"
grep -o -E 'Initial protocol [a-z0-9]+' /tmp/fwcheck.log | sort | uniq -c
echo "errors: $(grep -c -E ' ERR ' /tmp/fwcheck.log)"
grep -E ' (ERR|WRN) ' /tmp/fwcheck.log | tail -5 | cut -c1-200
rm -f /tmp/fwcheck.log

section "upgrade keep list"
sysupgrade -l 2>/dev/null | grep -i cloudflared || echo "nothing cloudflared in sysupgrade -l"
for f in /etc/backup_packages/*; do [ -e "$f" ] && echo "backup_packages: ${f##*/}"; done

section resources
df -h /overlay /tmp | tail -n +2
grep -E '^(MemTotal|MemAvailable)' /proc/meminfo
