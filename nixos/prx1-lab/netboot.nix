{
  config,
  pkgs,
  ...
}:
let
  netboot = config.host.site.lan.netboot;
in
{
  services.atftpd = {
    enable = true;
    root = "/var/lib/tftp";
    extraOptions = [
      "--bind-address"
      config.host.network.ipAddress
    ];
  };

  systemd.services.atftpd = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig.Restart = "on-failure";
  };

  networking.firewall.interfaces.vmbr0.allowedUDPPorts = [
    69 # TFTP
  ];

  systemd.tmpfiles.rules = [
    "L+ /var/lib/tftp/${netboot.bootFile} - - - - ${pkgs.netbootxyz-efi}"
  ];
}
