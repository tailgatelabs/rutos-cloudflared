# Keeping the package across firmware upgrades

> This is a kludge. RutOS has no supported way for a self-built package to survive a firmware upgrade. What the package does today relies on undocumented behaviour of RutOS 7.26, edits `/etc/rc.local`, and keeps an extra 9 MB copy of the package on flash. A future firmware can break it without notice. If it breaks, the fallback is the manual reinstall in the README.

Research notes from 2026-11-14, based on the scripts on a RUTM50 running RutOS 7.26.2, Teltonika's wiki, and the Teltonika community forum.

## What a firmware upgrade does

An upgrade with *Keep settings* writes a list of files to keep, flashes the new image, and restores those files on first boot. Everything else on the writable overlay is reset, including all of `/usr/local`, where opkg installs packages. Our config survives because our `keep.d` file lists it. The binary, init script, opkg record and boot links are gone afterwards. We confirmed this going from 7.26.1 to 7.26.2 (see [PLAN.md](../PLAN.md)).

The keep list accepts any file or directory. The test router already keeps `/root/.acme.sh/` through `/etc/sysupgrade.conf`. `/etc/rc.local` is on the default keep list and runs at the end of every boot.

## How RutOS restores its own packages

RutOS has a Package Restore feature on the Package Manager page. It's on by default (`package_restore.enabled=1` and `3rd_party_packages_enabled=1`), and it has two halves.

Before the upgrade, `/lib/functions/backup.sh` writes `/etc/package_restore.txt` and adds it to the keep list. It has one line for each installed package whose control file has an `AppName:` field:

- With `AppName` and `tlt_name`: `name - tlt_name - tlt_packages`, or `... - 3rd_party_packages` if the control file also says `Third-Party: True`.
- With `AppName` only: just the name.

After the upgrade, the `package_restore` service (`/sbin/package_restore.lua`, `START=99`, running as user `opkg`) works through three steps:

1. If `/etc/backup_packages/` holds any `*.ipk`, it moves them to `/tmp/backup_packages/`, runs `opkg install` on them, and deletes them if that succeeds.
2. It waits until Teltonika's feed servers answer, then installs each `tlt_packages` and `3rd_party_packages` line from `package_restore.txt` by name from Teltonika's two signed feeds.
3. If the hidden option `package_restore.3rd_party_pkg=1` is set, it installs the name-only lines from `/etc/opkg/openwrt/distfeeds.conf`. That directory doesn't exist on 7.26.

Nothing on the router writes to `/etc/backup_packages/`, and it isn't on the keep list. Teltonika's own tooling probably fills it (RMS, or backups that carry packages). The service runs at every boot, including ordinary reboots.

## Options we looked at

| Option | How it works | Cost and risk |
| --- | --- | --- |
| Seed `/etc/backup_packages/` | Keep our ipk there and let `package_restore` reinstall it | Doesn't work on its own. The service runs at every boot and deletes the ipk as soon as `opkg install` succeeds. opkg normally reports success for a package that's already installed, so the copy is likely gone after the next ordinary reboot (not tested). It also runs before `rc.local`, so a boot hook can't drop the ipk in on time |
| Our own feed through the legacy path | Add `AppName:` to the control file, host a signed opkg feed, put a `distfeeds.conf` and our signing key on the router, set `3rd_party_pkg=1` | No flash cost and always the newest version. We'd run and sign a feed, the feed must be named `openwrt_packages`, the restore loops forever if the feed is unreachable, and it relies on legacy code Teltonika has half removed |
| Kept copy plus a boot hook (built) | Keep the ipk and a small script in `/etc/cloudflared/`, list that folder in `keep.d`, and call the script from `/etc/rc.local` | 9 MB of flash, an edit to a file the user owns, and our own failure modes. Works offline and runs as root |
| Teltonika's third-party feed | Like ZeroTier: `Third-Party: True`, signed and hosted by Teltonika, restored by name | The only supported route. Needs a partnership with Teltonika, who would then control our releases |
| Manual reinstall | One `scp` and one `opkg install` after each firmware upgrade | No code, but the tunnel stays down until someone reinstalls, and that needs another way into the router |

Setting `tlt_name` so the package lands in the `tlt_packages` list doesn't work either. The restore would look for it in Teltonika's feed, fail, and show a failed package in the WebUI after every upgrade.

## What the package does

From `2026.11.0-r3`, `postinst` sets up three things, and `prerm` removes them when you uninstall (but not when you upgrade the package):

- `/etc/cloudflared/restore.sh`, a script that exits straight away if `cloudflared` is installed. Otherwise it runs `opkg install /etc/cloudflared/cloudflared.ipk`, retrying every 10 seconds for about 10 minutes, because Package Restore may still hold the opkg lock after an upgrade. It logs to syslog as `cloudflared-restore`.
- A line in `/etc/rc.local` that starts that script in the background at the end of boot. It ends in `# cloudflared-restore` so `prerm` can find it. `postinst` adds it once, before the final `exit 0`, and rewrites the file in place so its owner and mode don't change.
- `/etc/cloudflared/` in the package's `keep.d` file, so the folder comes through the upgrade.

The ipk in `/etc/cloudflared/cloudflared.ipk` is the one you install from. The README's install steps copy it there first, and `postinst` prints a warning if it's missing. Installing a newer version the same way replaces the copy, so a firmware upgrade never brings back an older version.

## Tests

### Package Restore with `/etc/backup_packages/` (RUTM50, 7.26.2)

We copied `cloudflared_2026.11.0-r2_mips32el-nf.ipk` into `/etc/backup_packages/`, ran `opkg remove cloudflared`, and rebooted. `package_restore` reinstalled the package about 45 seconds after it started, as user `opkg`. The boot links came back, `postinst` started the service, and 4 connections registered over QUIC within seconds. The config and token were untouched. Afterwards `/etc/backup_packages/` was empty.

That showed the restore works, but also why it can't be the whole answer: the copy is used once and deleted. The service also logged `tar: invalid magic` once. It opens each ipk with `tar -z` to see whether it's a Teltonika main package, and our ipk is an `ar` archive (so is Teltonika's zerotier ipk). The check fails and the package is treated as third-party, which is harmless.

### Boot hook scripts (BusyBox, in a container)

With `opkg`, `logger` and the init script stubbed out, under BusyBox ash:

- `postinst` adds the hook once, before `exit 0`, and keeps `rc.local` at `root:rclocal 0760`. Running it again adds nothing. If `rc.local` has no `exit 0`, the hook goes at the end.
- `restore.sh` does nothing without a kept ipk or while the binary exists, installs when the binary is missing, and gives up after 60 failed attempts.
- `prerm upgrade` leaves the hook and folder alone. `prerm remove` deletes both and keeps `rc.local`'s owner and mode.

## Not tested yet

- The whole flow on a router: install `-r3` from `/etc/cloudflared/`, then do a real firmware upgrade with *Keep settings*. Before upgrading, `sysupgrade -l` should list `/etc/cloudflared/cloudflared.ipk` and `/etc/cloudflared/restore.sh`.
- Whether a 9 MB file in the keep-settings backup causes trouble. The backup is held in RAM during the upgrade, and `/tmp` has over 100 MB free on both routers.
- How it behaves when Package Restore is still installing Teltonika packages and holding the opkg lock for more than 10 minutes, for example with no internet after the upgrade.

## Sources

- On the router: `/sbin/package_restore.lua`, `/etc/init.d/package_restore`, `/etc/init.d/rclocal`, `/lib/functions/backup.sh`, `/etc/permtab.d/package_restore`, `sysupgrade -l` (RUTM50, 7.26.2)
- [RUTM50 Package Manager](https://wiki.teltonika-networks.com/view/RUTM50_Package_Manager): Package Restore needs *Keep settings*, and an uploaded package is "Authorized" only if Teltonika signed it
- [Persistent Packages after Firmware Update](https://community.teltonika.lt/t/persistent-packages-after-firmware-update/13264): a user lost opkg-installed packages on a RUTX50, and staff couldn't reproduce it
- [Enrich Your IoT Solutions with the RutOS Package Manager](https://www.teltonika-networks.com/newsroom/enrich-your-iot-solutions-with-the-rutos-package-manager): Teltonika re-downloads packages after an upgrade
- [Preserving OpenWrt packages](https://openwrt.org/docs/guide-user/installation/sysupgrade.packages): the general OpenWrt approach
