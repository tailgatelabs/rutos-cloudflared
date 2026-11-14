# Handoff brief: cloudflared package for RutOS (RUTX11 + RUTM50)

Nov 14, 2026 · @Adam

## Goal and scope

The spike must prove that a self-built `cloudflared` ipk installs on a RUTX11 and a RUTM50, survives a reboot, and serves the router WebUI plus one LAN device UI through a Cloudflare Tunnel behind Access.

In scope:

- Cross-compiled `cloudflared` binaries for both devices
- A minimal ipk: binary, UCI config, procd init script
- A remotely-managed tunnel with ingress for the router UI and one LAN UI
- A CI job that rebuilds both ipks on each upstream release

Out of scope:

- Cloudflare One Client (WARP). It is closed-source and ships only for x86-64 and ARM64 glibc distros, so it cannot run on RutOS.
- A native RutOS WebUI (vuci) page
- Teltonika Package Manager bundles (`tar.gz` with `main` and `main.sig`) and signing
- Other device families. RUT9xx has 16 MB flash and needs a different storage strategy.

## Decisions already made

| Decision | Why |
| --- | --- |
| Build out-of-tree with upstream Go, not the Teltonika SDK | `cloudflared` is pure Go and links statically with `CGO_ENABLED=0`, so it has no libc coupling to RutOS. RUTX 7.22 still points its OpenWrt feed at 21.02, so the SDK's Go toolchain is probably too old. |
| Assemble the ipk with a script | An ipk is a gzipped tar of `debian-binary`, `control.tar.gz` and `data.tar.gz`. No SDK is needed and CI stays small. |
| One ipk per architecture | The `Architecture` field must match what opkg on the device accepts. |
| Remotely-managed (token) tunnel | Ingress lives in the Cloudflare dashboard or API. The router holds only a token, and LAN UIs can be added without touching it. |
| Token passed as `TUNNEL_TOKEN` env from procd | Keeps the token out of `ps` output. |
| Always run with `--no-autoupdate` | The package owns the binary version. |
| Install with `opkg install` over SSH during the spike | Package Manager upload shows unsigned packages as "Unauthorized" and adds nothing for a spike. |
| Use the OpenWrt `net/cloudflared` package as a template only | Its init script and UCI layout are a good reference. Its Makefile assumes the OpenWrt Go build system. |

## Build targets

Both binaries build from the same upstream tag with `CGO_ENABLED=0 GOOS=linux`; only the arch variables differ.

| Device | SoC | Go env | opkg arch | Confidence |
| --- | --- | --- | --- | --- |
| RUTX11 | Qualcomm IPQ40xx, Cortex-A7 | `GOARCH=arm GOARM=7` | `arm_cortex-a7_neon-vfpv4` | Arch string taken from Teltonika's RUTX SDK example |
| RUTM50 | MediaTek MT7621 (assumed) | `GOARCH=mipsle GOMIPS=softfloat` | `mipsel_24kc` (assumed) | Not confirmed for the M50; run `opkg print-architecture` |

```sh
git clone --depth 1 --branch "$TAG" https://github.com/cloudflare/cloudflared
cd cloudflared
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
  go build -trimpath -ldflags "-s -w -X main.Version=$TAG" \
  -o ../out/cloudflared-armv7 ./cmd/cloudflared
CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat \
  go build -trimpath -ldflags "-s -w -X main.Version=$TAG" \
  -o ../out/cloudflared-mipsle ./cmd/cloudflared
```

Upstream publishes `arm` and `armhf` Linux binaries but no `mipsle`, so build both from source for consistency. Take the Go version and any extra ldflags from the upstream `go.mod` and `Makefile` at that tag.

## Package layout

The ipk carries three files plus control metadata.

| Path | Mode | Notes |
| --- | --- | --- |
| `/usr/bin/cloudflared` | 0755 | Stripped static binary |
| `/etc/config/cloudflared` | 0600 | UCI config; listed in `conffiles` |
| `/etc/init.d/cloudflared` | 0755 | procd service |

UCI config:

```
config cloudflared 'main'
	option enabled '0'
	option token ''
	option protocol 'auto'
	option loglevel 'info'
```

`protocol` accepts `auto`, `quic` or `http2`.

Init script (starting point, untested):

```sh
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG=/usr/bin/cloudflared

start_service() {
	local enabled token protocol loglevel
	config_load cloudflared
	config_get_bool enabled main enabled 0
	config_get token main token
	config_get protocol main protocol auto
	config_get loglevel main loglevel info

	[ "$enabled" -eq 1 ] || return 0
	[ -n "$token" ] || { logger -t cloudflared "no token set"; return 1; }

	procd_open_instance
	procd_set_param command "$PROG" tunnel --no-autoupdate \
		--protocol "$protocol" --loglevel "$loglevel" run
	procd_set_param env TUNNEL_TOKEN="$token"
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger cloudflared
}
```

`respawn 3600 5 0` retries forever at 5 s intervals. That covers DNS and clock not being ready at boot.

Control file:

```
Package: cloudflared
Version: <upstream tag>-1
Architecture: <opkg arch>
Maintainer: <you>
Section: net
Description: Cloudflare Tunnel client (self-built for RutOS)
```

ipk assembly:

```sh
echo 2.0 > debian-binary
T="tar --numeric-owner --owner=0 --group=0 -czf"
$T control.tar.gz -C control .
$T data.tar.gz -C data .
$T "cloudflared_${VER}_${ARCH}.ipk" ./debian-binary ./data.tar.gz ./control.tar.gz
```

Add a `postinst` that enables the init script and a `prerm` that stops and disables it.

## Cloudflare-side tunnel design

Each router gets its own remotely-managed tunnel, with one public hostname per UI and an Access application in front of every hostname.

| Target | Service URL | Origin settings |
| --- | --- | --- |
| Router WebUI | `https://127.0.0.1:443` | `noTLSVerify: true` (self-signed cert) |
| Router WebUI, if HTTP to HTTPS redirect is off | `http://127.0.0.1:80` | none |
| LAN device UI | `http://<lan-ip>:<port>` | `httpHostHeader` if the device rejects the public hostname |

- Create the Access application and allow policy before adding the public hostname, so the UI is never reachable without it.
- Later option for many LAN UIs: a private network route for the LAN CIDR on the same tunnel. It covers non-HTTP too, but admin devices then need the Cloudflare One Client.
- The tunnel is outbound-only on port 7844 (TCP and UDP). It needs no inbound firewall rules and works behind CGNAT.

## Spike plan

Nine steps, each with a pass condition. Steps 1 to 5 need no packaging and settle the main risks first.

1. **Device facts.** On each router record `opkg print-architecture`, `uname -m`, firmware version, `df -h /overlay`, `free -m` and whether `/etc/ssl/certs` holds a CA bundle. Pass: the arch table above is confirmed or corrected.
2. **Cross-build.** Build both binaries from the latest upstream tag and record their sizes. Pass: `cloudflared --version` runs from `/tmp` on each device.
3. **Manual tunnel.** Run `TUNNEL_TOKEN=... cloudflared tunnel --no-autoupdate run` from `/tmp`. Pass: the connector shows healthy in the dashboard. Record the negotiated protocol and RSS.
4. **Router UI.** Add the Access app, then the public hostname. Pass: Access prompts first, then a full WebUI session works, including pages that poll or stream.
5. **LAN UI.** Add one LAN device hostname. Pass: its UI loads and logs in through the tunnel.
6. **ipk.** Build the package, `opkg install` it, set the token, enable the service. Pass: the tunnel comes back unattended after a cold boot and after a WAN drop or SIM failover.
7. **Protocol on cellular.** Compare `quic` and `http2` on the mobile WAN. Pass: a default is chosen per device.
8. **Firmware upgrade.** Upgrade with keep-settings on one device. Pass: it is known which of binary, init script and UCI config survive, and the reinstall steps are written down.
9. **CI.** A GitHub Actions workflow builds both ipks for a given upstream tag and attaches them with SHA-256 sums to a release. Pass: a clean run produces installable artifacts.

Suggested repo layout:

```
build.sh              # cross-compile both arches for $TAG
mkipk.sh              # assemble ipk from pkg/ and a binary
pkg/control/          # control, conffiles, postinst, prerm
pkg/data/etc/config/cloudflared
pkg/data/etc/init.d/cloudflared
.github/workflows/release.yml
```

## Unverified assumptions

None of these were checked on hardware; each is cheap to settle in steps 1 to 3 or 8.

| Assumption | How to check |
| --- | --- |
| RUTM50 is MT7621 with opkg arch `mipsel_24kc` | `opkg print-architecture`, `cat /proc/cpuinfo` |
| Both devices have enough overlay space for a binary of a few tens of MB | `df -h /overlay` against the built size |
| RutOS opkg installs a local unsigned ipk without extra flags | `opkg install /tmp/cloudflared_*.ipk` |
| A CA bundle is present where Go looks for it | `ls /etc/ssl/certs`; if absent, add a `Depends:` on the CA package |
| The WebUI listens on loopback and accepts a foreign `Host` header | `curl -kI -H 'Host: x.example.com' https://127.0.0.1/` on the router |
| Stock Go at the `go.mod` version builds a working binary for both targets | Step 2 |
| Softfloat MIPS handles QUIC at acceptable CPU cost on the M50 | `top` during step 7 |
| UCI config survives a firmware upgrade but the binary and init script do not | Step 8 |
| Cloudflare supports `cloudflared` versions for one year from release | Confirm in the Cloudflare Tunnel docs before setting CI cadence |

## Known gotchas

- **Clock at boot.** TLS to the Cloudflare edge fails until NTP has set the time. Rely on procd respawn; do not gate on interface events.
- **DNS at boot.** The edge lookup can fail before the WAN is up. Respawn covers this too.
- **QUIC on cellular.** Carriers sometimes throttle or block UDP 7844. Keep `protocol` in UCI so `http2` can be forced.
- **UDP buffer warning.** `cloudflared` may log that the kernel UDP receive buffer is too small. It is a warning; raise `net.core.rmem_max` only if QUIC throughput matters.
- **No `cloudflared service install`.** It assumes systemd or SysV. Use the procd script.
- **No log file on flash.** Send stdout and stderr to syslog through procd.
- **Token handling.** The token is the full tunnel credential. Keep the UCI file at 0600 and rotate the token if it leaks.
- **Proxied legacy UIs.** Absolute redirects and `Host` checks break some embedded UIs. Set `httpHostHeader` per hostname first.
- **Admin exposure.** Every hostname is an admin surface. Never publish one without an Access policy.

## References

- [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared): source and [releases](https://github.com/cloudflare/cloudflared/releases)
- [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/): flags and their `TUNNEL_*` env vars
- [RUTOS SDK instructions](https://wiki.teltonika-networks.com/view/RUTOS_Software_Development_Kit_instructions): source of the RUTX arch string
- [Cloudflared on RUT956](https://community.teltonika.lt/t/cloudflared-on-rut956/18040): community `mipsle` softfloat build
- [Cloudflare Tunnel on RUTC50](https://community.teltonika.lt/t/cloudflare-tunnel-on-rutc50-rutos/15803): community report of a working tunnel on RutOS
- [RUTX OS package format](https://community.teltonika.lt/t/rutx-os-package-format-ipk-file/13549): Package Manager bundle layout, for later
- [RUTX11 mosquitto thread](https://community.teltonika.lt/t/rutx11-rutx-r-00-07-22-3-need-compatible-mosquitto-sub-mosquitto-client-ssl-package/19527): shows RUTX 7.22 on an OpenWrt 21.02 feed
- [Cloudflare One Client requirements](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/download/lts-releases/): why WARP is out of scope
- OpenWrt `net/cloudflared` in the [openwrt/packages](https://github.com/openwrt/packages) feed: template for init script and UCI
