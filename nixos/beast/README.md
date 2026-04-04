# beast (NixOS)

This host is a storage/NAS node. The host-specific configuration lives in
`nixos/beast/default.nix`, and it is pulled in via the shared NixOS module in
`nixos/default.nix` (auto-upgrades, Avahi, timezone, etc.).

## What it runs

- NixOS with the latest stable kernel (`linuxPackages_latest`).
- Software RAID (`mdadm`) to assemble an existing RAID6 array.
- Btrfs for the data volume mounted at `/volume2`.
- NFS server exporting media and Nix cache paths to the local subnet.
- Snapper timelines and scheduled Btrfs scrubs for data hygiene.
- SMART monitoring for disk health.

## DDNS rollout (`jf.ihar.dev`, `au.ihar.dev`, `js.ihar.dev`)

`nixos/beast/default.nix` runs `services.ddclient` to update Dynu directly from
this host (instead of router-managed DDNS).

1. Create a Dynu hostname (current: `ihrachyshka-home.freeddns.org`).
1. In `nixos/beast/default.nix`, set:
   - `dynuHostname = "ihrachyshka-home.freeddns.org";`
   - `dynuUsername = "ihrachyshka";`
1. Add `ddns.dynu.password` to `secrets/beast.yaml` via `sops`.
1. Rebuild on beast.
1. At your registrar DNS, repoint:
   - `jf.ihar.dev CNAME <dynu-hostname>`
   - `au.ihar.dev CNAME <dynu-hostname>`
   - `js.ihar.dev CNAME <dynu-hostname>`

Validation:

```bash
dig +short jf.ihar.dev CNAME
dig +short au.ihar.dev CNAME
dig +short js.ihar.dev CNAME
dig +short ihrachyshka-home.freeddns.org A
systemctl status ddclient
journalctl -u ddclient -n 100 --no-pager
curl -I https://jf.ihar.dev
curl -I https://au.ihar.dev
curl -I https://js.ihar.dev
```

## Storage

- `/volume2` is a Btrfs filesystem mounted with `compress=zstd`, `noatime`, and
  `nofail`.
- A `.snapshots` subvolume is ensured on boot for Snapper.

Disk-to-Bay layout with identifying info can be found on Google Drive under
`hdd-NAS` directory.

## NFS

- Exports are restricted to `192.168.0.0/16` and currently include:
  - `/volume2/Media`
  - `/volume2/nix-cache`
- NFSv4 is enabled; NFSv3 is disabled.
- Firewall opens TCP/UDP 2049; `rpcbind` is forced off.

### Jellyfin write access for mixed-owner media trees

When download clients on other hosts create files with different owners/groups,
Jellyfin metadata jobs (trickplay/previews) can fail to write under
`/volume2/Media/library`.

Apply this one-time ACL repair on `beast` (recommended, directory-only):

```bash
sudo find /volume2/Media/library -xdev -type d \
  -exec setfacl -m u:jellyfin:rwx -m d:u:jellyfin:rwX {} +
```

Optional heavier pass (touches every file too):

```bash
sudo setfacl -R -m u:jellyfin:rwX /volume2/Media/library
```

Validation:

```bash
getfacl /volume2/Media/library | sed -n '1,20p'
getfacl /volume2/Media/library/<path-to-sample-file> | sed -n '1,20p'
```

Expected:

- Directories include both `user:jellyfin:rwx` and
  `default:user:jellyfin:rwX` (inheritance).
- New files created under those directories inherit `user:jellyfin:rw-`.

This keeps existing owners/groups intact and avoids broad `chmod 777`. Re-run
only if some later job strips ACLs.

## Maintenance and monitoring

- Snapper timeline snapshots for `/volume2` (daily/weekly/monthly/yearly).
- Monthly Btrfs scrub of `/volume2`.
- `smartd` autodetects disks for health monitoring.
- Useful tools installed: `btrfs-progs`, `mdadm`, `smartmontools`, `nvme-cli`,
  `hdparm`, `lm_sensors`.

## Jellyfin backups

`beast` can trigger Jellyfin's built-in backup API and then offload the
generated ZIP archives from `/var/lib/jellyfin/data/backups` into the local
restic repository at `/volume2/backups/restic-prod/hosts/beast`, which is then
offloaded to Backblaze B2 by the existing `beast` cloud sync flow.

Secrets required in `secrets/beast.yaml`:

- `jellyfin.apiKey`
- `backup.restic.beast.cloud.localPassword`
- `backup.restic.beast.cloud.password`

Relevant units:

- `jellyfin-built-in-backup.service`
- `restic-backups-beast.service`
- `restic-beast-cloud-offload.service`

Manual trigger:

```bash
sudo systemctl start jellyfin-built-in-backup.service
sudo systemctl start restic-backups-beast.service
sudo systemctl start restic-beast-cloud-offload.service
```

## Notes

- Disk layout is managed via the shared `../../disko` import.

## IPMI quirks

- If the BMC gets into a broken state, run: `sudo ipmitool raw 0x32 0x66`.
- On first setup, use a simple password (no special characters) or later
  logins can fail.

## SAS3008 quirk and firmware flashing

This host exposes two SAS3008 controllers to Linux:

- `04:00.0` (`host10`)
- `06:00.0` (`host11`)

Even though this may look like a single card physically, firmware is managed per
controller. `sas3flash -listall` can show different firmware on each controller.

### Why this matters

`/dev/md127` (RAID6) spans drives behind both controllers. Flashing one
controller while the array is active can drop multiple members at once.
Always do this with the array unmounted/stopped.

### Inspect current state

```bash
lspci -nn | grep -Ei 'SAS|LSI|Broadcom'
sudo ./sas3flash -listall
for d in /sys/block/sd*; do
  dev=$(basename "$d")
  path=$(readlink -f "$d/device")
  echo "$dev $path"
done | egrep 'host10|host11' | sort
```

### Safe flash procedure (offline)

1. Ensure no workloads are actively using `/volume2`:

```bash
nix shell nixpkgs#psmisc -c fuser -vm /volume2
sudo lsof +f -- /volume2
```

1. Unmount and stop array:

```bash
sudo umount /volume2
cat /proc/mdstat
sudo mdadm --stop /dev/md127
cat /proc/mdstat
```

1. Flash the target controller explicitly (example: controller 1):

```bash
cd ~/SAS3FLASH\ P16-V17.00.00.00/sas3flash_rel/sas3flash/sas3flash_linux_x86_rel
sudo ./sas3flash -listall
sudo ./sas3flash -c 1 -list
sudo ./sas3flash -c 1 -o -f ~/IT/UEFI/3008IT16.ROM -b ~/IT/UEFI/mptsas3.rom
sudo ./sas3flash -c 1 -list
sudo ./sas3flash -listall
```

1. Reboot and bring storage back:

```bash
sudo reboot
```

After reboot:

```bash
dmesg -T | rg 'mpt3sas_cm[01].*FWVersion'
cat /proc/mdstat
sudo mdadm --assemble --scan   # only if not auto-assembled
sudo mount /volume2
sudo btrfs device stats /volume2
```

### Post-flash notes

- If Linux `sas3flash` cannot access one controller, use UEFI shell with
  `sas3flash.efi` and the same `-c <N>` targeting.
- Keep firmware versions aligned across both SAS3008 controllers.

## HDD bay map

Document confirmed physical bay positions here after drive moves or cable
changes. Prefer serial numbers over `/dev/sdX`, since Linux device names can
change across boots.

| Bay | Serial   | Model                |
| --- | -------- | -------------------- |
| 1   | ZYD01W48 | ST24000NM000H-3KS103 |
| 3   | ZYD0CASB | ST24000NM000H-3KS103 |
| 5   | ZYD05Z4J | ST24000NM000H-3KS103 |
| 6   | ZYD041CP | ST24000NM000H-3KS103 |
| 7   | ZXA0RKFF | ST24000NM000C-3WD103 |
| 9   | ZXA0B5K4 | ST24000NM000C-3WD103 |
| 10  | ZXA0FFNN | ST24000NM000C-3WD103 |
| 11  | ZYD01W92 | ST24000NM000H-3KS103 |
| 13  | ZYD02EQQ | ST24000NM000H-3KS103 |
| 15  | ZXA0GW38 | ST24000NM000C-3WD103 |
