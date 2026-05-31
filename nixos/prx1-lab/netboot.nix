{
  hostInventory,
  hostname,
  pkgs,
  ...
}:
let
  netboot = hostInventory.site.lan.netboot;
  hostSpec = hostInventory.nixosHostSpecsByName.${hostname};
in
{
  services.atftpd = {
    enable = true;
    root = "/var/lib/tftp";
    extraOptions = [
      "--bind-address"
      hostSpec.ipAddress
    ];
  };

  networking.firewall.interfaces.vmbr0.allowedUDPPorts = [
    69 # TFTP
  ];

  systemd.tmpfiles.rules = [
    "L+ /var/lib/tftp/${netboot.bootfile} - - - - ${pkgs.netbootxyz-efi}"
  ];
}
