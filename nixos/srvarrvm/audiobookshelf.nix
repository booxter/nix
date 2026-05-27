{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  port = 9292;
  stateDir = "${config.host.srvarrPaths.stateDir}/audiobookshelf";
  user = "audiobookshelf";
  audiobookshelfService = hostInventory.servicesById.audiobookshelf;
in
{
  services.audiobookshelf = {
    enable = true;
    dataDir = stateDir;
    group = "media";
    port = port;
    user = user;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  # Upstream assumes dataDir lives under /var/lib; keep only the overrides
  # needed for the absolute state path we use on srvarr.
  systemd.services.audiobookshelf.serviceConfig.WorkingDirectory = lib.mkForce stateDir;

  users.users.${user} = {
    home = lib.mkForce "/var/empty";
    uid = accounts.uids.audiobookshelf;
  };

  host.internalHttps.services.audiobookshelf = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    serverAliases = [ audiobookshelfService.publicHost ];
    mtls.enable = true;
  };
}
