{
  config,
  lib,
  srvarrPkgs,
  ...
}:
let
  accounts = import ./accounts.nix { hostAccounts = config.host.accounts; };
  stateDir = "${config.host.srvarrPaths.stateDir}/seerr";
  user = "seerr";
  group = "seerr";
in
{
  host.backups.sources.seerr-database = {
    title = "Seerr";
    capture = {
      type = "sqlite";
      database = {
        path = "${stateDir}/db/db.sqlite3";
        destinationDir = "${config.host.srvarrPaths.stateDir}/seerr-backup/latest";
        extraCopies = [
          { source = "${stateDir}/settings.json"; }
        ];
      };
    };
  };

  services.seerr = {
    enable = true;
    configDir = stateDir;
  };

  environment.systemPackages = [ srvarrPkgs.seerr-tools ];

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.seerr.serviceConfig = {
    Group = group;
    ReadWritePaths = [ stateDir ];
    StateDirectory = lib.mkForce "seerr";
    User = user;
  };

  users.groups.${group}.gid = accounts.gids.seerr;
  users.users.${user} = {
    group = group;
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.seerr;
  };

  host.web.services.seerr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
    public = {
      enable = true;
      hostName = "js.${config.host.network.publicDomain}";
    };
    health.frontend = {
      enable = true;
      path = "/login";
    };
    observability.importance = "important";
    presentation.dashboard = {
      enable = true;
      section = "user";
    };
  };
}
