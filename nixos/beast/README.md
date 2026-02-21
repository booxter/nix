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

2. Unmount and stop array:

```bash
sudo umount /volume2
cat /proc/mdstat
sudo mdadm --stop /dev/md127
cat /proc/mdstat
```

3. Flash the target controller explicitly (example: controller 1):

```bash
cd ~/SAS3FLASH\ P16-V17.00.00.00/sas3flash_rel/sas3flash/sas3flash_linux_x86_rel
sudo ./sas3flash -listall
sudo ./sas3flash -c 1 -list
sudo ./sas3flash -c 1 -o -f ~/IT/UEFI/3008IT16.ROM -b ~/IT/UEFI/mptsas3.rom
sudo ./sas3flash -c 1 -list
sudo ./sas3flash -listall
```

4. Reboot and bring storage back:

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

### Notes

- If Linux `sas3flash` cannot access one controller, use UEFI shell with
  `sas3flash.efi` and the same `-c <N>` targeting.
- Keep firmware versions aligned across both SAS3008 controllers.
