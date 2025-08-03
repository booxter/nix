{ ... }:
{
  imports = [
    ../../disko/prx-lab.nix
  ];
  # TODO: automatically sync with dhcp config
  services.proxmox-ve.ipAddress = "192.168.15.12";
}
