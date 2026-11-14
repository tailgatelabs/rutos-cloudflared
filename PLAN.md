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
- **Flash:** a stripped `cloudflared` is likely 30 to 40 MB. That fits on both, but on the RUTM50 it uses more than half of the free overlay. opkg also needs room in `/tmp` (RAM) for the downloaded ipk while it installs, so install from a file copied to `/tmp` and delete it afterwards.
- **RAM is the tighter limit.** There's no swap. The RUTX11 has about 54 MiB available with RutOS running. If `cloudflared` uses 30 to 50 MiB RSS, the router runs with very little headroom, and the kernel OOM killer could take out `cloudflared` or a RutOS service. M0 has to measure this.

All device facts are now recorded. M0 only has to measure the binary size and RSS.

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
- Shipped as a separate, arch-independent package (`vuci-app-cloudflared`, `Architecture: all`) that depends on `cloudflared`. UI changes then don't need a rebuild per arch, and upstream binary releases don't touch the UI.

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
mkipk.sh                        # mkipk.sh <tag> <target> -> out/cloudflared_<ver>_<arch>.ipk
pkg/control/                    # control.in, conffiles, postinst, prerm
pkg/data/etc/config/cloudflared
pkg/data/etc/init.d/cloudflared
.github/workflows/release.yml   # scheduled + manual: check upstream, build, test, release
README.md
PLAN.md
```

Phase 2 adds `vuci/` with its own small packaging step. It reuses `mkipk.sh` if the layout allows.

### Build and release flow

1. The workflow runs daily and on manual dispatch. It reads the latest upstream release tag.
2. If a release with that tag already exists in this repo, it stops. Otherwise it continues.
3. It checks out upstream at the tag, sets up Go from upstream's `go.mod` (`actions/setup-go` with `go-version-file`), and runs `build.sh` for every line in `targets`.
4. `mkipk.sh` assembles one ipk per target.
5. Smoke tests, all cheap and on the runner:
   - Run `cloudflared --version` for each binary under `qemu-user` and check it prints the tag.
   - List each ipk's contents and check paths, modes and the `Architecture` field.
   - Run `shellcheck` on the scripts and the init script.
6. It publishes a GitHub release named after the upstream tag, with both ipks and a `SHA256SUMS` file.

Package version is `<upstream tag>-r<n>`, for example `2026.11.0-r1`. `n` goes up only when packaging changes without a new upstream tag. A manual dispatch with a `pkgrel` input covers that case.

### Package contents

| Path | Mode | Notes |
| --- | --- | --- |
| `/usr/bin/cloudflared` | 0755 | Stripped static binary |
| `/etc/init.d/cloudflared` | 0755 | procd service, starts disabled |
| `/etc/config/cloudflared` | 0600 | UCI config, listed in `conffiles` so upgrades keep it |
| `/usr/share/licenses/cloudflared/LICENSE` | 0644 | Upstream Apache-2.0 license |

`postinst` enables the init script but doesn't start the service until `enabled=1` and a token are set. `prerm` stops the service.

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

- How RutOS 7.26 WebUI loads apps. Inspect an installed `vuci-app-*` package on a device (`opkg files`, `/www`, API definitions) to see what a page consists of once installed.
- Whether a page can be shipped as prebuilt files in an ipk, or whether it needs the Teltonika SDK's frontend build. If it needs the SDK, weigh that cost against a minimal alternative before committing, for example a plain status page.
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
| RutOS major firmware release | Re-run the M1 install, reboot and upgrade checks on one device | About 30 minutes per major release |
| New device family | Add a line to `targets` if its arch is not already covered | Minutes, plus one hardware check |
| GitHub Actions versions | Optional Dependabot for `github-actions` only, monthly | Merge a PR occasionally |

Cloudflare supports `cloudflared` releases for about a year. Following upstream automatically keeps us well inside that. Confirm the exact policy in M2.

## Risks and open questions

| Item | Impact | Plan |
| --- | --- | --- |
| GitHub disables scheduled workflows after 60 days without repo activity | Releases silently stop | Check in M2 whether workflow-created releases count as activity. If not, add a monthly keepalive or accept a manual dispatch now and then |
| Firmware upgrade wipes the binary and init script | Tunnel down after upgrade until reinstalled | Measure in M1. If confirmed, document the reinstall, and test whether listing the files in `/etc/sysupgrade.conf` from `postinst` keeps them |
| Low RAM: about 54 MiB available on the RUTX11, 69 MiB on the RUTM50, no swap | OOM kills of `cloudflared` or RutOS services | Measure RSS in M0. Cap the Go heap with `GOMEMLIMIT` from procd if needed |
| Overlay fits a ~35 MB binary on both, but it takes more than half of the RUTM50's 55.9 MB free | Little room for other packages, and an upgrade may need space for old and new binaries at once | Measure the real size in M0. Check in M1 whether `opkg upgrade` needs double the space. UPX is the last resort |
| Softfloat QUIC CPU cost on the RUTM50 | High load, slow UI | Measure in M1. Force `http2` per device if needed |
| VuCI needs the Teltonika SDK to build | Phase 2 gets heavy | P2.0 decides before any UI work |
| Repo visibility and license | Affects who can install from releases | Open: public or private repo? MIT or Apache-2.0 for our scripts? |
| GitHub org and repo name | Release URLs in the README | Open |
| `test-teltonika-details.txt` holds internal hostnames and an IP | Leaks into git history if committed | Facts are copied into this plan. Leave the file out of the first commit or gitignore it |
