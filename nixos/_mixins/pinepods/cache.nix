{
  config,
  lib,
  pinepodsModel,
  pkgs,
  ...
}:
let
  inherit (pinepodsModel) cachePort cfg user;
  passwordSecret = "pinepods/valkey/password";
in
{
  config = lib.mkIf (cfg != null) {
    sops.secrets.${passwordSecret} = {
      mode = "0400";
      restartUnits = [
        "pinepods-valkey.service"
        "podman-pinepods.service"
      ];
    };

    sops.templates."pinepods-valkey.conf" = {
      owner = user;
      group = config.users.users.${user}.group;
      mode = "0400";
      content = ''
        bind 127.0.0.1
        protected-mode yes
        port ${toString cachePort}
        daemonize no
        supervised no
        dir /run/pinepods-valkey
        save ""
        appendonly no
        requirepass ${config.sops.placeholder.${passwordSecret}}
      '';
      restartUnits = [ "pinepods-valkey.service" ];
    };

    systemd.services.pinepods-valkey = {
      description = "PinePods Valkey cache and task queue";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [ "podman-pinepods.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.valkey}/bin/valkey-server ${config.sops.templates."pinepods-valkey.conf".path}";
        User = user;
        Group = config.users.users.${user}.group;
        RuntimeDirectory = "pinepods-valkey";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        RemoveIPC = true;
      };
    };
  };
}
