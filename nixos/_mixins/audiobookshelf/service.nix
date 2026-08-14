{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  libraries = builtins.attrValues model.libraries;
  readablePaths = map (library: library.media.path) (
    builtins.filter (library: library.media != null && library.access == "readOnly") libraries
  );
  writablePaths = map (library: library.media.path) (
    builtins.filter (library: library.media != null && library.access == "readWrite") libraries
  );
in
{
  config = lib.mkIf (cfg != null) {
    services.audiobookshelf = {
      enable = true;
      package = cfg.package;
      dataDir = cfg.stateDir;
      group = cfg.group;
      port = cfg.port;
      user = cfg.user;
    };

    users.users.${cfg.user} = {
      group = cfg.group;
      home = lib.mkForce "/var/empty";
      isSystemUser = true;
    };

    # Upstream assumes dataDir lives under /var/lib. An absolute
    # StateDirectory is ignored by systemd, so retain only settings that work
    # for arbitrary state paths.
    systemd.services.audiobookshelf.serviceConfig = {
      StateDirectory = lib.mkForce null;
      WorkingDirectory = lib.mkForce cfg.stateDir;
      ReadOnlyPaths = readablePaths;
      ReadWritePaths = [ cfg.stateDir ] ++ writablePaths;
      LockPersonality = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      RemoveIPC = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };
}
