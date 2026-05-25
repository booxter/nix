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
    host = "127.0.0.1";
    port = cfg.port;
    user = cfg.user;
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
    "d '${mediaDir}/library/audiobooks' 0775 root media - -"
    "d '${mediaDir}/library/podcasts' 0775 root media - -"
  ];

  systemd.services.audiobookshelf.serviceConfig = {
    IOSchedulingPriority = 0;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    PrivateDevices = true;
    PrivateMounts = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ReadWritePaths = [ cfg.stateDir ];
    RemoveIPC = true;
    Restart = "on-failure";
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    StateDirectory = lib.mkForce null;
    WorkingDirectory = lib.mkForce cfg.stateDir;
  };

  users.users.${cfg.user} = {
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.audiobookshelf;
  };
}
