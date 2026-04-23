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
- Disk-to-bay mapping is maintained in `nixos/beast/default.nix`.

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

## HBA firmware flashing

As of the 2026-04 controller swap, `beast` uses a single Broadcom / LSI
`SAS9305-24i` (`SAS3224`) HBA instead of the old dual-`SAS3008` setup.

Current Linux identity:

- `02:00.0` Broadcom / LSI `SAS3224`
- typical boot log: `mpt3sas_cm0: LSISAS3224: FWVersion(...)`

The flashing workflow is automated with the flake app `.#hba-flash`. The app
ships with pinned Broadcom bundles by default:

- `SAS3FLASH_P15.zip` for the Linux `sas3flash` utility
- `9305_24i_Pkg_P16.12_IT_FW_BIOS_for_MSDOS_Windows.zip` for the
  `SAS9305_24i_IT_P.bin` firmware image

By default the app flashes only the HBA firmware `.bin`. It does not flash the
BIOS or UEFI option ROMs unless `--optionrom` is passed explicitly.

### Why this matters

`/dev/md127` (RAID6) spans the storage behind this controller. Do not flash it
while `/volume2` is mounted or while `md127` is active. Quiesce the host first.

### Preflight

Run a read-only controller preflight:

```bash
nix run .#hba-flash --
```

This stages the pinned Broadcom artifacts, checks controller visibility with
`sas3flash -listall`, and prints the current md/mount/service state on `beast`.

### Safe flash procedure (offline)

1. Ensure no workloads are actively using `/volume2`:

```bash
nix shell nixpkgs#psmisc -c fuser -vm /volume2
sudo lsof +f -- /volume2
```

1. Run the automated flash:

```bash
nix run .#hba-flash -- --flash
```

The app stops Jellyfin/NFS, unmounts `/media` and `/volume2`, stops `md127`,
stages `sas3flash`, and flashes controller `0`.

1. Reboot and bring storage back:

```bash
sudo reboot
```

After reboot:

```bash
dmesg -T | rg 'mpt3sas_cm0.*FWVersion'
cat /proc/mdstat
sudo mdadm --assemble --scan   # only if not auto-assembled
sudo mount /volume2
sudo btrfs device stats /volume2
```

### Override inputs when needed

If Broadcom posts a newer bundle, or if you want to test a locally downloaded
ZIP first, the app can override either side explicitly:

```bash
nix run .#hba-flash -- --sas3flash-bundle /path/to/SAS3FLASH.zip \
  --firmware-bundle /path/to/9305_24i_firmware.zip
```

or:

```bash
nix run .#hba-flash -- --sas3flash /path/to/sas3flash \
  --firmware /path/to/SAS9305_24i_IT_P.bin
```

### Post-flash notes

- If Linux `sas3flash` cannot access the controller, use a UEFI shell with
  `sas3flash.efi`.
- If this host is moved to another HBA model later, update this section and the
  pinned bundles in `lib/fleet.nix` together.
