{
  config,
  lib,
  webModel,
  ...
}:
let
  aliasAddress = config.host.network.ipAddress;
  aliases = webModel.localAliases;
  aliasService = alias: {
    name = "avahi-alias-${alias}";
    value = {
      description = "Avahi mDNS host alias ${alias}.local";
      after = [ "avahi-daemon.service" ];
      requires = [ "avahi-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${config.services.avahi.package}/bin/avahi-publish-address"
          "-f"
          "-R"
          "${alias}.local"
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
    hostName = config.networking.hostName;
  };

  systemd.services = builtins.listToAttrs (map aliasService aliases);
}
