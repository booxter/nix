{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      pkgs
      ;
  };
  inherit (model) cfg state;
in
{
  config = lib.mkIf (cfg.enable && model.ready) {
    systemd.services.romm-valkey = {
      description = "RomM Valkey cache and queue";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-tmpfiles-setup.service"
        "systemd-tmpfiles-resetup.service"
      ];
      unitConfig.RequiresMountsFor = builtins.dirOf cfg.stateDir;
      serviceConfig = {
        ExecStart = "${pkgs.valkey}/bin/valkey-server --bind 127.0.0.1 --port ${toString cfg.cache.port} --dir ${state.valkeyDir} --appendonly yes --save 60 1";
        User = cfg.user;
        Group = model.storageGroup;
        WorkingDirectory = state.valkeyDir;
        UMask = "0007";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ state.valkeyDir ];
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
