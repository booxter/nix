{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.aurral;
  adminUsers = lib.attrNames (
    lib.filterAttrs (
      _: person: lib.any (group: builtins.elem group person.groups) cfg.authProxy.adminGroups
    ) config.host.sso.users
  );
in
{
  config = lib.mkIf cfg.enable {
    fonts.packages = [ pkgs.dejavu_fonts ];

    users.groups.aurral = { };
    users.users.aurral = {
      isSystemUser = true;
      group = "aurral";
      extraGroups = cfg.extraGroups;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 aurral aurral - -"
      "z ${cfg.stateDir} 0750 aurral aurral - -"
    ];

    systemd.services.aurral = {
      description = "Aurral music discovery and flow download service";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        Wants = [ "network-online.target" ];
        After = [ "network-online.target" ];
        RequiresMountsFor = [ cfg.flowDir ] ++ cfg.extraWritePaths;
      };
      path = [
        pkgs.coreutils
        pkgs.ffmpeg
        pkgs.yt-dlp
      ];
      environment = {
        AURRAL_DATA_DIR = cfg.stateDir;
        DOWNLOAD_FOLDER = cfg.flowDir;
        WEEKLY_FLOW_FOLDER = cfg.flowDir;
        PORT = toString cfg.port;
        TRUST_PROXY = "2";
      }
      // lib.optionalAttrs cfg.authProxy.enable {
        AUTH_PROXY_ENABLED = "true";
        AUTH_PROXY_HEADER = "x-forwarded-user";
        AUTH_PROXY_ADMIN_USERS = lib.concatStringsSep "," adminUsers;
        AUTH_PROXY_DEFAULT_ROLE = "user";
        AUTH_PROXY_TRUSTED_IPS = "127.0.0.1,::1";
        DISABLE_LOCAL_AUTH = "true";
      };
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        User = "aurral";
        Group = "aurral";
        WorkingDirectory = cfg.stateDir;
        UMask = "0007";
        Restart = "on-failure";
        RestartSec = "5s";
        LimitNOFILE = 65536;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.stateDir
          cfg.flowDir
        ]
        ++ cfg.extraWritePaths;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        LockPersonality = true;
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
