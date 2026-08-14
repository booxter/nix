{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg selected;
  slskdEnabled = cfg != null;
  adminGroup = if model.ssoApplication == null then null else model.ssoApplication.adminGroup;
  adminUsers = lib.attrNames (
    lib.filterAttrs (
      _: person: adminGroup != null && builtins.elem adminGroup person.groups
    ) config.host.sso.users
  );
in
{
  config = lib.mkIf (cfg != null) {
    fonts.packages = [ pkgs.dejavu_fonts ];

    users.groups.${model.user} = { };
    users.users.${model.user} = {
      isSystemUser = true;
      group = model.user;
      extraGroups = lib.unique ([ model.group ] ++ lib.optionals slskdEnabled [ selected.group ]);
    };

    sops.templates."aurral-slskd.env" = lib.mkIf slskdEnabled {
      owner = model.user;
      group = model.user;
      mode = "0400";
      restartUnits = [ "aurral.service" ];
      content = ''
        AURRAL_SLSKD_API_KEY=${config.sops.placeholder."${selected.secretPrefix}/web/apiKey"}
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${model.user} ${model.user} - -"
      "z ${cfg.stateDir} 0750 ${model.user} ${model.user} - -"
    ];

    host.storage.claims.${cfg.storageClaim} = {
      directories.${model.flowRelativePath} = {
        group = model.group;
        mode = "2775";
      };
      attachments.aurral.unit = "aurral";
    };

    systemd.services.aurral = {
      description = "Aurral music discovery and flow download service";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        Wants = [ "network-online.target" ];
        After = [ "network-online.target" ] ++ lib.optional slskdEnabled "${selected.unitName}.service";
        Requires = lib.optional slskdEnabled "${selected.unitName}.service";
      };
      path = [
        pkgs.coreutils
        pkgs.ffmpeg
        pkgs.yt-dlp
      ];
      environment = {
        AURRAL_DATA_DIR = cfg.stateDir;
        DOWNLOAD_FOLDER = model.flowDir;
        WEEKLY_FLOW_FOLDER = model.flowDir;
        PORT = toString model.port;
        TRUST_PROXY = "2";
      }
      // lib.optionalAttrs slskdEnabled {
        AURRAL_SLSKD_MANAGED = "true";
        AURRAL_SLSKD_URL = selected.apiUrl;
        AURRAL_SLSKD_PRIORITY = "10";
        AURRAL_SLSKD_PREFERRED_FORMAT = "flac";
        AURRAL_SLSKD_STRICT_FORMAT = "false";
        AURRAL_SLSKD_CLEANUP_AFTER_RUNS = "true";
      }
      // {
        AUTH_PROXY_ENABLED = "true";
        AUTH_PROXY_HEADER = "x-forwarded-user";
        AUTH_PROXY_ADMIN_USERS = lib.concatStringsSep "," adminUsers;
        AUTH_PROXY_DEFAULT_ROLE = "user";
        AUTH_PROXY_TRUSTED_IPS = "127.0.0.1,::1";
        DISABLE_LOCAL_AUTH = "true";
      };
      serviceConfig = {
        ExecStart = lib.getExe (pkgs.callPackage ./package { });
        EnvironmentFile = lib.optional slskdEnabled config.sops.templates."aurral-slskd.env".path;
        User = model.user;
        Group = model.user;
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
          model.flowDir
        ]
        ++ lib.optional slskdEnabled selected.completedDir;
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
