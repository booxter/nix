{
  config,
  hostInventory,
  lib,
  pkgs,
  srvarrPkgs,
  ...
}:
let
  aurralPort = 3001;
  mediaPath = config.host.srvarrPaths.mediaDir;
  aurralStateDir = "${config.host.srvarrPaths.stateDir}/aurral";
  aurralFlowDir = "${mediaPath}/library/flows";
  slskdDownloadsDir = "${mediaPath}/slskd/complete";
  aurralService = hostInventory.servicesById.aurral;
  aurralAdminUsers = lib.attrNames (
    lib.filterAttrs (_: person: builtins.elem "media-admins" person.groups) hostInventory.sso.users
  );
  aurralUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
    RequiresMountsFor = mediaPath;
  };
  imageProxyCacheZone = "aurral_images";
  imageProxyCacheLocation = {
    proxyPass = "http://127.0.0.1:${toString aurralPort}";
    recommendedProxySettings = true;
    extraConfig = ''
      proxy_cache ${imageProxyCacheZone};
      proxy_cache_background_update on;
      proxy_cache_lock on;
      proxy_cache_revalidate on;
      proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    '';
  };
  aurralImageLocations = {
    # Only cache-key responses have public cache semantics. Do not share-cache
    # playlist or discovery artwork because those handlers enforce user access.
    "^~ /api/image-proxy/" = imageProxyCacheLocation;
  };
in
{
  # Sharp resolves fonts through fontconfig when rendering playlist artwork.
  fonts.packages = [ pkgs.dejavu_fonts ];

  users.groups.aurral = { };
  users.users.aurral = {
    isSystemUser = true;
    group = "aurral";
    extraGroups = [ "media" ];
  };

  systemd.tmpfiles.rules = [
    "d ${aurralStateDir} 0750 aurral aurral - -"
    "z ${aurralStateDir} 0750 aurral aurral - -"
    # A cache root retained from an older nginx user must remain traversable
    # after nginx switches users or cached response bodies cannot be served.
    "d /var/cache/nginx/aurral-images 0750 nginx nginx - -"
  ];

  systemd.services.aurral = {
    description = "Aurral music discovery and flow download service";
    wantedBy = [ "multi-user.target" ];
    unitConfig = aurralUnitDeps;
    path = [
      pkgs.coreutils
      # Aurral only needs FFmpeg for yt-dlp extraction and metadata remuxing;
      # those operations do not require the full optional feature set.
      pkgs.ffmpeg
      pkgs.yt-dlp
    ];
    environment = {
      AURRAL_DATA_DIR = aurralStateDir;
      DOWNLOAD_FOLDER = aurralFlowDir;
      WEEKLY_FLOW_FOLDER = aurralFlowDir;
      PORT = toString aurralPort;
      # Public access traverses beast nginx first and then the local srvarr
      # nginx proxy in front of the app.
      TRUST_PROXY = "2";
      # Browser SSO is enforced by oauth2-proxy on beast. Aurral has no native
      # OIDC support, so it trusts only this proxy-provided username header
      # and rejects app-local password login.
      AUTH_PROXY_ENABLED = "true";
      AUTH_PROXY_HEADER = "x-forwarded-user";
      AUTH_PROXY_ADMIN_USERS = lib.concatStringsSep "," aurralAdminUsers;
      AUTH_PROXY_DEFAULT_ROLE = "user";
      AUTH_PROXY_TRUSTED_IPS = "127.0.0.1,::1";
      DISABLE_LOCAL_AUTH = "true";
    };
    serviceConfig = {
      ExecStart = lib.getExe srvarrPkgs.aurral;
      User = "aurral";
      Group = "aurral";
      WorkingDirectory = aurralStateDir;
      UMask = "0007";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 65536;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        aurralStateDir
        aurralFlowDir
        # Aurral validates and moves completed slskd downloads into its
        # separate flow library.
        slskdDownloadsDir
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

  host.internalHttps.services.aurral = {
    enable = true;
    upstream = "http://127.0.0.1:${toString aurralPort}";
    publicAliases = [ aurralService.publicHost ];
    mtls.enable = true;
    probe.enable = true;
  };

  services.nginx.proxyCachePath.aurral-images = {
    enable = true;
    keysZoneName = imageProxyCacheZone;
    keysZoneSize = "1m";
    inactive = "7d";
    maxSize = "256m";
  };

  # Cache only immutable cache-key responses. The query-based warming endpoint
  # remains on the normal proxy path because Aurral still emits it for misses.
  services.nginx.virtualHosts."internal-https-aurral".locations = aurralImageLocations;
  services.nginx.virtualHosts.${aurralService.publicHost}.locations = aurralImageLocations;

  # Aurral's OAuth gate lives on beast because only the public hostname is
  # browser-protected. The backend probe still needs a probe-only listener on
  # the service owner, so define this exact health location locally on srvarr.
  services.nginx.virtualHosts."internal-https-aurral-probe".locations."= /api/health/live" = {
    proxyPass = "http://127.0.0.1:${toString aurralPort}";
    recommendedProxySettings = true;
    extraConfig = ''
      auth_request off;
    '';
  };
}
