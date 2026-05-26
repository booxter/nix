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

  systemd.services.audiobookshelf.serviceConfig = {
    # Keep the upstream unit shape, but add explicit hardening around the
    # absolute state directory layout we use on srvarr.
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
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    WorkingDirectory = lib.mkForce cfg.stateDir;
  };

  users.users.${cfg.user} = {
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.audiobookshelf;
  };
}
