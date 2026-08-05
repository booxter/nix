{
  config,
  hostSpecName,
  hostInventory,
  lib,
  ...
}:
let
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};

  aliasAddress = hostInventory.toHostIpv4Address hostSpec;
  aliases = lib.unique ((hostSpec.localDnsAliases or [ ]) ++ config.host.internalHttps.localAliases);
  aliasService = alias: {
    name = "avahi-alias-${alias}";
    value = {
      description = "Avahi mDNS host alias ${hostInventory.toLocalDnsName alias}";
      after = [ "avahi-daemon.service" ];
      requires = [ "avahi-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${config.services.avahi.package}/bin/avahi-publish-address"
          "-f"
          "-R"
          (hostInventory.toLocalDnsName alias)
          aliasAddress
        ];
        Restart = "on-failure";
        RestartSec = "5s";
        User = "avahi";
        Group = "avahi";
      };
    };
  };
in
{
  services.avahi = {
    enable = true;
    # NixOS uses separate knobs for v4/v6 NSS.
    nssmdns4 = true;
    nssmdns6 = true;
    # Ensure this host publishes its name/address over mDNS.
    publish = {
      enable = true;
      userServices = true;
      addresses = true;
    };
    hostName = hostSpec.name;
  };

  systemd.services = builtins.listToAttrs (builtins.map aliasService aliases);
}
