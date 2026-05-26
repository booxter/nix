{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/prowlarr";
  user = "prowlarr";
  group = "prowlarr";
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
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.prowlarr = {
    unitConfig = {
      Wants = [ "network-online.target" ];
      After = [ "network-online.target" ];
    };
    serviceConfig = {
      # `User` and `Group` override `DynamicUser = true` from the NixOS
      # Prowlarr module because a matching static account exists.
      User = user;
      Group = group;
      ExecStart = lib.mkForce "${config.services.prowlarr.package}/bin/Prowlarr -nobrowser -data=${stateDir}";
      ReadWritePaths = [ stateDir ];
    };
  };

  users = {
    groups = {
      ${group}.gid = accounts.gids.prowlarr;
      prowlarr-api = { };
    };
    users.${user} = {
      isSystemUser = true;
      group = group;
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
