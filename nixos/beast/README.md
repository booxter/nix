# beast (NixOS)

This host is a storage/NAS node. The host-specific configuration lives in
`nixos/beast/default.nix`, and it is pulled in via the shared NixOS module in
`nixos/default.nix` (auto-upgrades, Avahi, timezone, etc.).

## What it runs

- NixOS with the LTS kernel (`linuxPackages_6_12`).
- Software RAID (`mdadm`) to assemble an existing RAID6 array.
- Btrfs for the data volume mounted at `/volume2`.
- NFS server exporting media and Nix cache paths to the local subnet.
- Snapper timelines and scheduled Btrfs scrubs for data hygiene.
- SMART monitoring for disk health.

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

## Maintenance and monitoring

- Snapper timeline snapshots for `/volume2` (daily/weekly/monthly/yearly).
- Monthly Btrfs scrub of `/volume2`.
- `smartd` autodetects disks for health monitoring.
- Useful tools installed: `btrfs-progs`, `mdadm`, `smartmontools`, `nvme-cli`,
  `hdparm`, `lm_sensors`.

## Notes

- Disk layout is managed via the shared `../../disko` import.

## IPMI quirks

- If the BMC gets into a broken state, run: `sudo ipmitool raw 0x32 0x66`.
- On first setup, use a simple password (no special characters) or later logins can fail.
