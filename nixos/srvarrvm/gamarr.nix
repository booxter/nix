{
  config,
  lib,
  pkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  mediaDir = config.host.srvarrPaths.mediaDir;
  # Match RomM's upstream data-root layout: ROM files live below
  # ${rommBasePath}/library, alongside resources/assets/config.
  rommBasePath = "${mediaDir}/romm";
  romsPath = "${rommBasePath}/library/roms";
  stateDir = "${config.host.srvarrPaths.stateDir}/gamarr";
  user = "gamarr";
  port = 5091;
  tmpfilesSetupUnits = [
    "systemd-tmpfiles-setup.service"
    "systemd-tmpfiles-resetup.service"
  ];
in
{
  sops.secrets = {
    "gamarr/authPassword" = { };
    "gamarr/apiKey" = { };
    "prowlarr/apiKey" = { };
  };

  sops.templates."gamarr.env" = {
    owner = user;
    group = "media";
    mode = "0400";
    content = ''
      AUTH_PASSWORD=${config.sops.placeholder."gamarr/authPassword"}
      API_KEY=${config.sops.placeholder."gamarr/apiKey"}
      TORZNAB_API_KEY=${config.sops.placeholder."gamarr/apiKey"}
      # Mirror the existing Prowlarr UI-generated API key. Do not use this
      # secret to override or rotate Prowlarr's own config.
      PROWLARR_API_KEY=${config.sops.placeholder."prowlarr/apiKey"}
      SABNZBD_API_KEY=${config.sops.placeholder."sabnzbd/apiKey"}
    '';
    restartUnits = [ "gamarr.service" ];
  };

  users.users.${user} = {
    isSystemUser = true;
    group = "media";
    home = stateDir;
    uid = accounts.uids.gamarr;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0750 ${user} media - -"
    "d '${romsPath}/pc' 2775 ${user} media - -"
  ];

  systemd.services.gamarr = {
    description = "Gamarr game and ROM manager";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
      "sabnzbd.service"
      "transmission.service"
    ]
    ++ tmpfilesSetupUnits;
    unitConfig.RequiresMountsFor = [
      mediaDir
      stateDir
    ];
    path = [
      pkgs.coreutils
      pkgs.p7zip
      pkgs.unrar
    ];
    environment = {
      GAMARR_PORT = toString port;
      DATA_DIR = stateDir;
      GAMES_ROMS_PATH = romsPath;
      GAMES_VAULT_PATH = "${romsPath}/pc";
      AUTH_USERNAME = "ihar";
      # Gamarr defaults qBittorrent and Prowlarr to container hostnames.
      # Disable qBittorrent explicitly; this host uses Transmission/SABnzbd.
      QB_URL = "";
      PROWLARR_URL = "http://127.0.0.1:${toString config.services.prowlarr.settings.server.port}";
      # TODO: When Prowlarr indexers are managed declaratively, compute this
      # from the same indexer declaration.
      PROWLARR_GAME_INDEXERS = "3,5,6,7,8,10,13";
      SABNZBD_URL = "http://127.0.0.1:${toString config.services.sabnzbd.settings.misc.port}";
      TRANSMISSION_URL = "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}";
      ROMM_URL = "https://game.ihar.dev";
      EXTRACT_ARCHIVES = "true";
      # The watcher only monitors qBittorrent completions. Leave it off until
      # we either add qBittorrent or upstream extends it to Transmission/SABnzbd.
      WATCHER_ENABLED = "false";
    };
    serviceConfig = {
      ExecStart = lib.getExe pkgs.gamarr;
      EnvironmentFile = config.sops.templates."gamarr.env".path;
      User = user;
      Group = "media";
      WorkingDirectory = stateDir;
      UMask = "0002";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 65536;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        stateDir
        romsPath
      ];
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

  host.internalHttps.services.gamarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
  };
}
