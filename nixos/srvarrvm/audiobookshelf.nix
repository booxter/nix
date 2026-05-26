{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.audiobookshelf;
  mediaDir = config.host.srvarr.mediaDir;
in
{
  services.audiobookshelf = {
    enable = true;
    dataDir = cfg.stateDir;
    group = cfg.group;
    port = cfg.port;
    user = cfg.user;
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  # Upstream assumes dataDir lives under /var/lib; keep only the overrides
  # needed for the absolute state path we use on srvarr.
  systemd.services.audiobookshelf.serviceConfig.WorkingDirectory = lib.mkForce cfg.stateDir;

  users.users.${cfg.user} = {
    home = lib.mkForce "/var/empty";
    uid = accounts.uids.audiobookshelf;
  };
}
