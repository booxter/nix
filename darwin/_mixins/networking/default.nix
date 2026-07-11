{
  hostInventory,
  hostname,
  isWork,
  lib,
  ...
}:
let
  lan = hostInventory.site.lan;
in
{
  environment.etc."resolver/${lan.domain}".text = ''
    nameserver ${lan.gateway.address}
  '';

  # Can't configure networking on managed work devices
  networking = lib.optionalAttrs (!isWork) {
    knownNetworkServices =
      # mair - laptop - doesn't have builtin ethernet
      lib.optionals (hostname != "mair") [
        "Ethernet"
      ]
      ++ [
        "Wi-Fi"
      ];
    computerName = hostname;
    dhcpClientId = hostname;
  };
}
