# rutos-cloudflared: project plan

Draft 1 · 2026-11-14

## What this project is

A self-built `cloudflared` package for Teltonika RutOS routers, so a router can expose its own WebUI and selected LAN device UIs through a Cloudflare Tunnel behind Cloudflare Access. No inbound ports, works behind CGNAT.

The MVP is an installable ipk for the RUTX11 and the RUTM50 that rebuilds itself when upstream ships a release. Phase 2 adds a native RutOS WebUI (VuCI) page for configuring the tunnel and checking its status.

Background, early decisions and gotchas are in [the handoff brief](CLAUDE_RESEARCH_HANDOFF_BRIEF.md). This plan does not repeat them. Where the two disagree, this plan wins.

## Maintenance principles

The project should cost close to nothing to keep alive. Every design choice below is checked against these rules.

1. **No fork, no patches.** Build `cloudflared` from an unmodified upstream tag. If something needs a patch, we push it upstream or work around it in packaging.
2. **No SDK, no toolchain to maintain.** Stock Go, picked from upstream's `go.mod` at the tag. The ipk is assembled with `tar` and `gzip` from a POSIX shell script.
3. **One source of truth for targets.** The arch matrix lives in a single file (`targets`) that the build script, the packaging script and CI all read. Adding a device family is a one-line change.
4. **Releases happen without a human.** A scheduled workflow notices a new upstream tag, builds, smoke-tests and publishes. A human is needed only when that run fails, and GitHub emails on failure.
5. **Small surface.** Three installed files, four UCI options, two shell scripts, one workflow. Anything that adds a moving part (UPX, a hosted opkg feed, a test framework, Makefiles) stays out until a concrete problem needs it.
6. **The UCI config is the contract.** The init script reads it in the MVP and the VuCI page writes it in phase 2. Options can be added later. Renaming or removing one is a breaking change.

## Device facts (confirmed 2026-11-14)

From `opkg print-architecture`, `uname -a` and the login banner on both test routers. Both run 7.26.1, the latest RutOS firmware as of this draft:

| | RUTX11 | RUTM50 |
| --- | --- | --- |
| Firmware | `RUTX_R_00.07.26.1` | `RUTM_R_00.07.26.1` |
| Test router | `workshop-router` | `benz-router` |
| Kernel | 6.6.137 | 6.12.77 |
| `uname -m` | `armv7l` | `mips` |
| BusyBox | 1.36.1 | 1.36.1 |
| Highest generic arch | `cortexa7hf-neon-vfpv4` | `mips32r2el-1004kc-nf` |
| Machine arch | `rutx` | `rutm` |
| CPU | ARMv7 rev 5 (Cortex-A7), hard float, NEON | MediaTek MT7621, MIPS 1004Kc V2.15, no FPU |
| Overlay free | 71.1 MB of 81.6 MB | 55.9 MB of 75.6 MB |
| RAM total / available | 240 MiB / 54 MiB | 225 MiB / 69 MiB |
| Swap | none | none |
| CA bundle | `/etc/ssl/certs/ca-certificates.crt` | `/etc/ssl/certs/ca-certificates.crt` |

This corrects the brief in two places:

- **Arch strings.** RutOS 7.26 uses OpenEmbedded-style arch names. The brief's `arm_cortex-a7_neon-vfpv4` and `mipsel_24kc` are not in either device's list, so packages built with those names would be refused.
- **Firmware baseline.** Both devices run 7.26.1, not 7.22. The brief's note about an OpenWrt 21.02 feed is out of date. It doesn't change anything because we build outside the SDK anyway.

It also confirms the MT7621 assumption for the RUTM50 (1004Kc is the MT7621 core) and that `GOMIPS=softfloat` is required (`-nf`).

`uname -m` reports `mips` on the RUTM50 whatever the byte order, so the little-endian part comes from the `el` in its opkg arches, not from `uname`.

BusyBox `free` ignores `-m` and prints KiB, so the RAM figures above are converted from KiB.

What these numbers mean:

- **CA bundle:** Go reads `/etc/ssl/certs/ca-certificates.crt` by default, so the package needs no CA dependency.
- **Flash:** the 2026.11.0 build is 24.6 MB (armv7) and 27.9 MB (mipsle) stripped, and the ipks are about 9 MB. That fits on both, but on the RUTM50 it uses half of the free overlay. opkg also needs room in `/tmp` (RAM) for the ipk while it installs, so copy it to `/tmp` and delete it afterwards.
- **RAM is the tighter limit.** There's no swap. The RUTX11 has about 54 MiB available with RutOS running. If `cloudflared` uses 30 to 50 MiB RSS, the router runs with very little headroom, and the kernel OOM killer could take out `cloudflared` or a RutOS service. M0 has to measure this.

All device facts are now recorded. M0 only has to measure RSS.

### How RutOS 7.26 installs packages

Found on the RUTX11 and confirmed against Teltonika's own `zerotier` ipk:

- RutOS 7.26 is built with Yocto (Poky), not the OpenWrt build system. opkg is 0.6.3 with libsolv. That's why the arch names are OpenEmbedded-style.
- The root filesystem is read-only squashfs. opkg's default dest is `/usr/local` (an overlay), and `/usr/local/etc` is a symlink to `/etc`. So `./usr/bin/cloudflared` in the ipk lands at `/usr/local/usr/bin/cloudflared` (on `PATH`), and `./etc/...` lands in `/etc` as usual.
- Teltonika's init scripts handle both locations with `PROG=/usr/bin/x; [ -x "$PROG" ] || PROG="/usr/local$PROG"`. Ours does the same, so the same package also works on plain OpenWrt.
- Packages list config files to keep across firmware upgrades in `./lib/upgrade/keep.d/<pkg>`. Ours lists `/etc/config/cloudflared`.
- `option check_signature` is set for the feeds, but a local unsigned ipk installs without extra flags (confirmed on the RUTM50).
- Teltonika's ipk uses a GNU `ar` outer archive with `control.tar.gz` and `data.tar.zst`. Ours is `ar` with gzip for both, which opkg's libarchive also reads.

The router WebUI listens on `0.0.0.0:443` and `:80` and serves `https://127.0.0.1/` with a foreign `Host` header (200 on both routers). So the tunnel service for the router UI is `https://127.0.0.1:443` with TLS verification off.

## Targets

| Target id | Go env | ipk `Architecture` | Installs on |
| --- | --- | --- | --- |
| `armv7` | `GOARCH=arm GOARM=7` | `armv7ahf-vfp` | RUTX11 and any RutOS device listing that arch |
| `mipsle` | `GOARCH=mipsle GOMIPS=softfloat` | `mips32el-nf` | RUTM50 and any RutOS device listing that arch |

The `Architecture` field names the lowest ISA the Go binary actually needs, not the device. Both strings appear in the device lists above. This gives two packages total instead of one per model, and other devices on the same CPU family can install them without a rebuild. The machine arches (`rutx`, `rutm`) are deliberately not used.

M1 has to confirm that opkg accepts these generic strings. If it doesn't, fall back to `cortexa7hf-neon-vfpv4` and `mips32r2el-1004kc-nf`. That's a one-line change in `targets`.

## Scope

### MVP

- Cross-compiled static `cloudflared` for both targets, built from the latest upstream tag
- One ipk per target: binary, UCI config, procd init script, upstream license
- A remotely managed (token) tunnel serving the router WebUI and one LAN UI behind Access
- A GitHub Actions workflow that builds, smoke-tests and releases both ipks when upstream tags a release
- A README covering install, configure, upgrade, uninstall, token rotation and the Cloudflare-side setup order

### Phase 2: VuCI UI

- A RutOS WebUI page to enable or disable the tunnel, set the token, protocol and log level, and see service and connector status
- Shipped as separate, arch-independent packages (`Architecture: all`) that depend on `cloudflared`. UI changes then don't need a rebuild per arch, and upstream binary releases don't touch the UI.

Teltonika's own ZeroTier UI shows the shape to copy. It's two `all` packages:

- `vuci-app-zerotier-api`: Lua handlers in `/usr/lib/lua/api/services/`, an rpcd ACL in `/usr/share/rpcd/acl.d/`, and a route in `/usr/share/vuci/path.d/`. This is plain text and easy to ship.
- `vuci-app-zerotier-ui`: one compiled, gzipped JS bundle in `/www/assets/` and a menu entry in `/usr/share/vuci/menu.d/`. The bundle is built by Teltonika's frontend toolchain, and that is the main maintenance risk for phase 2.

### Not planned

- Cloudflare One Client (WARP). It's closed source and glibc-only.
- Locally managed tunnels (credentials file plus local `config.yml`). Ingress stays in the dashboard or API.
- Teltonika Package Manager bundles and signing. Revisit only if Teltonika gives third parties a signing path.
- A hosted opkg feed. GitHub release assets are enough until someone manages a fleet.
- RUT9xx and other 16 MB flash devices
- Binary compression (UPX). It adds RAM cost and a tool to maintain. Revisit only if overlay space turns out to be tight.

## Design

### Repo layout

```
targets                         # target id, GOARCH/GOARM/GOMIPS, ipk arch (one line each)
build.sh                        # build.sh <tag> [target...] -> out/cloudflared-<target>
mkipk.sh                        # mkipk.sh <tag> <target> [pkgrel] -> out/cloudflared_<ver>_<arch>.ipk
check.sh                        # check.sh <tag> <ipk...>: layout, modes, arch, runs binary under qemu
tools/fwcheck.sh                # read-only router snapshot, run before and after a firmware upgrade
pkg/control/                    # control.in, conffiles, postinst, prerm
pkg/data/etc/config/cloudflared
pkg/data/etc/init.d/cloudflared
pkg/data/lib/upgrade/keep.d/cloudflared
.github/workflows/release.yml   # scheduled + manual: check upstream, build, test, release
README.md
PLAN.md
```

Phase 2 adds `vuci/` with its own small packaging step. It reuses `mkipk.sh` if the layout allows.

### Build and release flow

1. The workflow runs daily and on manual dispatch. It reads the latest upstream release tag.
2. If a release with that tag already exists in this repo, it stops. Otherwise it continues.
3. `build.sh` clones upstream at the tag and sets `GOTOOLCHAIN` to the Go version in upstream's `go.mod`, as upstream's Makefile does. It builds with upstream's ldflags, plus `-s -w`, `-trimpath` and `BuiltForPackageManager=opkg`, for every line in `targets`.
4. `mkipk.sh` assembles one ipk per target.
5. Smoke tests, all cheap and on the runner:
   - Run `cloudflared --version` for each binary under `qemu-user` and check it prints the tag.
   - List each ipk's contents and check paths, modes and the `Architecture` field.
   - Run `shellcheck` on the scripts and the init script.
6. It publishes a GitHub release named `<tag>-r<n>`, with both ipks and a `SHA256SUMS` file.

Packages are reproducible: mtimes come from the upstream commit, owners are `root`, and the outer `ar` archive is written by the script itself. Rebuilding on the same host gives byte-identical ipks. GNU tar (CI) and bsdtar (macOS) produce different bytes, so CI output is the reference.

Package version is `<upstream tag>-r<n>`, for example `2026.11.0-r1`. `n` goes up only when packaging changes without a new upstream tag. A manual dispatch with a `pkgrel` input covers that case.

### Package contents

| Path | Mode | Notes |
| --- | --- | --- |
| `/usr/bin/cloudflared` | 0755 | Stripped static binary |
| `/etc/init.d/cloudflared` | 0755 | procd service, starts disabled |
| `/etc/config/cloudflared` | 0600 | UCI config, listed in `conffiles` so upgrades keep it |
| `/lib/upgrade/keep.d/cloudflared` | 0644 | Keeps the UCI config across firmware upgrades |
| `/usr/share/licenses/cloudflared/LICENSE` | 0644 | Upstream Apache-2.0 license |

Paths are relative to the opkg dest. On RutOS, `/usr/...` lands under `/usr/local/usr/...`.

`postinst` enables the init script and calls `start`, which does nothing until `enabled=1` and a token are set. `prerm` stops the service, and on removal (not upgrade) it also disables it.

### UCI contract

```
config cloudflared 'main'
	option enabled '0'          # 0|1
	option token ''             # tunnel token from the dashboard
	option protocol 'auto'      # auto|quic|http2
	option loglevel 'info'      # debug|info|warn|error|fatal
```

The init script is the one in the brief: it passes the token through the `TUNNEL_TOKEN` environment variable, always runs with `--no-autoupdate`, logs to syslog and respawns forever. Phase 2 will probably want a status source. `cloudflared` serves a local metrics and readiness endpoint, and the init script should pin its address (`--metrics 127.0.0.1:<port>`) so the UI has a fixed place to read from. That would be the only option added for phase 2, and it can be added when phase 2 starts.

## MVP milestones

Each milestone has an exit check. Steps refer to the spike plan in the brief.

Status at 2026-11-14:

| Milestone | Done | Left |
| --- | --- | --- |
| M0 | Device facts. 2026.11.0 cross-built (24.6 / 27.9 MB). Both binaries run under qemu. WebUI loopback and `Host` behaviour checked | Run on hardware, manual tunnel, RSS, router UI and LAN UI behind Access |
| M1 | Scripts and `pkg/` written. Both ipks built and pass `check.sh` and shellcheck. The mipsle ipk was installed and works on the RUTM50, so opkg accepts the generic `mips32el-nf` arch and an unsigned local ipk. Firmware upgrade tested on the RUTM50 (see below) | RUTX11 install. On both: reboot, WAN drop, SIM failover, quic vs http2 |

### Firmware upgrade result (RUTM50, 7.26.1 → 7.26.2, keep settings on)

Taken with `tools/fwcheck.sh` before and after:

| Item | After the upgrade |
| --- | --- |
| `/etc/config/cloudflared` | Kept, unchanged (mode 0600, `enabled=1`, token intact). It's on the `sysupgrade -l` list through our `keep.d` entry |
| Binary, init script, `keep.d` entry, license | Removed. The whole `/usr/local` overlay is reset |
| opkg record | Removed. `opkg list-installed` no longer shows the package |
| Boot links in `/etc/rc.d` | Removed |
| `/etc/backup_packages` | Empty before and after, so RutOS doesn't reinstall third-party packages itself |

Reinstalling the CI-built `2026.11.0-r1` ipk afterwards with `opkg install` brought the tunnel back on its own: 4 connections over QUIC, the old token used, and the boot links restored. opkg kept the existing config and wrote the package's template to `/etc/config/cloudflared-opkg`. That file would then be carried through every later upgrade, so from `-r2` `postinst` deletes it. It also showed that `build.sh` printed the build time in the build machine's local time zone, so the Mac and CI builds disagreed. From `-r2` it's forced to UTC.

The RUTM50 before the upgrade, with the tunnel up for six days: `cloudflared` used 35.6 MB RSS, and 42.7 MB was still available (MemAvailable). After the upgrade without `cloudflared`, 87.8 MB was available, but that's just after boot, so the two figures aren't directly comparable. QUIC was the protocol chosen on that WAN.

`cloudflared` logs a warning at start that the ICMP proxy is disabled because GID 0 is outside `ping_group_range`. That only matters for private network routing with the Cloudflare One Client, which is out of scope, so we leave it.
| M2 | Public repo `tailgatelabs/rutos-cloudflared`. First manual run published `2026.11.0-r1` with both ipks and `SHA256SUMS`, after fixing qemu packaging on Ubuntu 26.04 runners. The CI-built mipsle ipk was installed on the RUTM50 and works | Watch the first unattended scheduled release |
| M3 | README written | Repo license, visibility and org |

### M0: Hardware spike (brief steps 1 to 5)

Settle the risks before writing any packaging.

- Cross-build both binaries by hand and run `--version` from `/tmp`. Record binary sizes against free overlay.
- Run a token tunnel by hand from `/tmp`. Record the negotiated protocol on both devices, plus RSS at idle and during WebUI use, and `MemAvailable` from `/proc/meminfo` while it runs. Note that a binary run from `/tmp` also takes its own size out of RAM, so measure RSS from the overlay copy if `/tmp` space gets tight.
- If RAM is tight, try `GOMEMLIMIT` (for example `GOMEMLIMIT=30MiB`, set from procd) before anything else. It's an env var with no code change.
- Publish the router WebUI behind Access, creating the Access app before the hostname. Check that a full session works, including pages that poll.
- Publish one LAN device UI the same way.

**Exit:** both devices hold a healthy connector and both UIs work through Access. Any finding that changes this plan is written back into it.

### M1: Package (brief steps 6 to 8)

- Write `targets`, `build.sh`, `mkipk.sh` and `pkg/`.
- `opkg install` the local ipk on both devices and confirm the generic arch strings are accepted.
- Check that the tunnel comes back unattended after a cold boot, a WAN drop, and a SIM failover on the RUTM50.
- Compare `quic` and `http2` on the cellular WAN and choose the shipped default. Keep `auto` unless one device needs otherwise.
- Upgrade firmware with keep-settings on one device. Record which of the binary, init script and UCI config survive, and write down the reinstall steps.

**Exit:** a package built by the scripts installs, survives reboots and failover, and the post-firmware-upgrade procedure is known.

### M2: Automated releases (brief step 9)

- Write `release.yml` as described above.
- Run it once by hand for the current upstream tag, then let the schedule take over.

**Exit:** a clean run with no human input produces a release whose ipks install on both devices.

### M3: Docs and first public release

- README: what it is and isn't, install from a release, configure with `uci`, upgrade, uninstall, rotate the token, re-install after a firmware upgrade, Cloudflare setup order (Access policy first, then hostname), and the `httpHostHeader` hint for legacy UIs.
- Pick the repo license and visibility. See the open questions.

**MVP is done** when someone with a RUTX11 or RUTM50 can go from the README to a working tunnel without help, and the next upstream release ships without anyone touching the repo.

## Phase 2: VuCI UI

### P2.0: Research spike

The answers here decide whether the UI can stay lightweight, so this comes first.

- How RutOS 7.26 WebUI loads apps. Partly answered: see the ZeroTier layout under Scope. Still open is how the `menu.d` and `path.d` JSON and the Lua API are structured.
- Whether a page can be shipped as prebuilt files in an ipk, or whether it needs the Teltonika SDK's frontend build. The ZeroTier UI is a compiled bundle, so assume the SDK is needed until shown otherwise. If it needs the SDK, weigh that cost against a minimal alternative before committing, for example a plain status page.
- How the UI reads and writes UCI and reads service state through the RutOS API, and whether unsigned packages are allowed to register menu entries and API endpoints.
- How the page behaves across a firmware upgrade.

**Exit:** a short written finding with a go or no-go on a native page and the chosen build approach.

### P2.1 to P2.3: Build it

- **P2.1 Settings:** enabled, token (write-only field, never echoed back), protocol and log level, bound to the UCI contract.
- **P2.2 Status:** service running or stopped, connector ready (from the pinned metrics endpoint), version, and a link to recent syslog lines.
- **P2.3 Package and release:** `vuci-app-cloudflared` as an `all` arch ipk, released next to the binary packages by the same workflow, but rebuilt only when `vuci/` changes.

**Phase 2 is done** when a user can install both packages, paste a token in the WebUI, and see the connector come up without SSH.

## Ongoing maintenance

What should happen, and what it costs:

| Event | What happens | Human effort |
| --- | --- | --- |
| Upstream release | Scheduled workflow builds and publishes it | None |
| Upstream changes Go version or build flags | Picked up from `go.mod` automatically. If the build breaks, the workflow fails and GitHub emails | Fix `build.sh`, rerun |
| Packaging fix | Commit, then dispatch with `pkgrel` bumped | Minutes |
| RutOS major firmware release | Run `tools/fwcheck.sh` before and after upgrading one device, diff the two, and reinstall if needed | About 30 minutes per major release |
| New device family | Add a line to `targets` if its arch is not already covered | Minutes, plus one hardware check |
| GitHub Actions versions | Optional Dependabot for `github-actions` only, monthly | Merge a PR occasionally |

Cloudflare supports `cloudflared` releases for about a year. Following upstream automatically keeps us well inside that. Confirm the exact policy in M2.

## Risks and open questions

| Item | Impact | Plan |
| --- | --- | --- |
| GitHub disables scheduled workflows after 60 days without repo activity | Releases silently stop | Check in M2 whether workflow-created releases count as activity. If not, add a monthly keepalive or accept a manual dispatch now and then |
| Firmware upgrade removes the package (confirmed 7.26.1 → 7.26.2 on the RUTM50) | Tunnel down after every firmware upgrade until reinstalled | Documented reinstall for now. The config with the token survives, so a reinstall brings the tunnel straight back. Listing the binary and init script in `keep.d` would leave files opkg no longer knows about, and the boot links would still be lost, so we don't. Worth checking later: whether `opkg install <release URL>` works straight from the router, which would make the reinstall one command |
| Low RAM: about 54 MiB available on the RUTX11, 69 MiB on the RUTM50, no swap | OOM kills of `cloudflared` or RutOS services | Measure RSS in M0. Cap the Go heap with `GOMEMLIMIT` from procd if needed |
| The 27.9 MB mipsle binary takes half of the RUTM50's 55.9 MB free overlay | Little room for other packages, and an upgrade may need space for old and new binaries at once | Check in M1 whether `opkg upgrade` needs double the space. If so, document `opkg remove` then install. UPX is the last resort |
| Softfloat QUIC CPU cost on the RUTM50 | High load, slow UI | Measure in M1. Force `http2` per device if needed |
| VuCI needs the Teltonika SDK to build | Phase 2 gets heavy | P2.0 decides before any UI work |
| Repo visibility and license | Affects who can install from releases | Open: public or private repo? MIT or Apache-2.0 for our scripts? |
| GitHub org and repo name | Release URLs in the README | Open |
| `Maintainer:` field in the control file | Shown by `opkg info` | Set to "Tailgate Labs" as a placeholder. Confirm |
