{
  config,
  lib,
  ...
}:
let
  lan = config.host.site.lan;
  networkServiceFor =
    interface:
    {
      ethernet = "Ethernet";
      wireless = "Wi-Fi";
    }
    .${interface.kind};
in
{
  environment.etc."resolver/${config.host.network.lanDomain}".text = ''
    nameserver ${lan.gateway.address}
  '';

  # Can't configure networking on managed work devices
  networking = lib.optionalAttrs config.host.management.manageNetworkIdentity {
    knownNetworkServices = lib.unique (
      map networkServiceFor (builtins.attrValues config.host.network.interfaces)
    );
    computerName = config.networking.hostName;
    dhcpClientId = config.networking.hostName;
  };
}
