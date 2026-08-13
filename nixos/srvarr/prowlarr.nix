{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix { hostAccounts = config.host.accounts; };
  servarrCommon = import ./servarr-common.nix { inherit config lib; };
  stateDir = "/data/.state/nixarr/prowlarr";
  user = "prowlarr";
  group = "prowlarr";
in
lib.mkMerge [
  (servarrCommon.mkServarrService { name = "prowlarr"; })
  {
    host.web.api.prowlarr = {
      service = "prowlarr";
      interface = "prowlarr";
      localUnit = "prowlarr.service";
      allowedCidrs = [ "${config.host.network.ipAddress}/32" ];
      authentication.apiKey = {
        source = "${stateDir}/config.xml";
        field = "ApiKey";
      };
    };

    host.backups.sources.prowlarr = {
      title = "Prowlarr";
      capture.type = "scheduled";
      capture.scheduled.outputPaths = [ "${stateDir}/Backups" ];
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
  }
]
