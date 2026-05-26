{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.prowlarr;
in
{
  services.prowlarr = {
    enable = true;
    settings = {
      log.analyticsEnabled = false;
      server.bindaddress = "127.0.0.1";
      update = {
        automatically = false;
        mechanism = "external";
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  systemd.services.prowlarr = {
    unitConfig = {
      Wants = [ "network-online.target" ];
      After = [ "network-online.target" ];
    };
    serviceConfig = {
      # `User` and `Group` override `DynamicUser = true` from the NixOS
      # Prowlarr module because a matching static account exists.
      User = cfg.user;
      Group = cfg.group;
      ExecStart = lib.mkForce "${config.services.prowlarr.package}/bin/Prowlarr -nobrowser -data=${cfg.stateDir}";
      ReadWritePaths = [ cfg.stateDir ];
    };
  };

  users = {
    groups = {
      ${cfg.group}.gid = accounts.gids.prowlarr;
      prowlarr-api = { };
    };
    users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/empty";
      uid = accounts.uids.prowlarr;
      extraGroups = [ "prowlarr-api" ];
    };
  };

  host.internalHttps.services.prowlarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.prowlarr.settings.server.port}";
  };
}
