{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
  adminGroup = if model.ssoApplication == null then null else model.ssoApplication.roles.admin;
  adminUsers = lib.attrNames (
    lib.filterAttrs (
      _: person: adminGroup != null && builtins.elem adminGroup person.groups
    ) config.host.sso.users
  );
  browserOrigin = "https://${cfg.publicHostName}";
  allowedGroups =
    if model.ssoApplication == null then [ ] else builtins.attrValues model.ssoApplication.roles;
  cacheZone = "aurral_images";
  cacheLocation = {
    proxyPass = "http://127.0.0.1:${toString model.port}";
    recommendedProxySettings = true;
    extraConfig = ''
      proxy_cache ${cacheZone};
      proxy_cache_background_update on;
      proxy_cache_lock on;
      proxy_cache_revalidate on;
      proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    '';
  };
  imageLocations."^~ /api/image-proxy/" = cacheLocation;
in
{
  config = lib.mkIf (cfg != null) {
    fonts.packages = [
      pkgs.dejavu_fonts
      pkgs.noto-fonts-color-emoji
    ];

    users.users.${model.user}.extraGroups = [ model.group ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${model.user} ${model.user} - -"
      "z ${cfg.stateDir} 0750 ${model.user} ${model.user} - -"
      "d /var/cache/nginx/aurral-images 0750 nginx nginx - -"
    ];

    host.storage.claims.${cfg.storageClaim} = {
      directories.${model.flowRelativePath} = {
        group = model.group;
        mode = "2775";
      };
      attachments.aurral = { };
    };

    host.backups.sources.aurral-database = {
      title = "Aurral";
      database = {
        type = "sqlite";
        path = "${cfg.stateDir}/aurral.db";
        stagingDir = "${cfg.stateDir}-backup/latest";
      };
    };

    host.web.services.aurral = {
      upstream = "http://127.0.0.1:${toString model.port}";
      auth = {
        oauth2ProxyGate = {
          displayName = "Aurral";
          port = 4181;
          inherit allowedGroups;
          groupClaim = "media_groups";
          externalOrigin = browserOrigin;
          internalHttpsServiceNames = [ "aurral" ];
          authRequestHeaders = {
            X-Forwarded-User = "x_auth_request_preferred_username";
            X-Forwarded-Email = "x_auth_request_email";
            X-Forwarded-Groups = "x_auth_request_groups";
          };
          sessionRefresh = {
            intervalSeconds = 14 * 60;
            lifetimeSeconds = 8 * 60 * 60;
          };
        };
      };
    };

    services.nginx = {
      proxyCachePath.aurral-images = {
        enable = true;
        keysZoneName = cacheZone;
        keysZoneSize = "1m";
        inactive = "7d";
        maxSize = "256m";
      };
      virtualHosts = {
        "internal-https-aurral".locations = imageLocations;
        ${cfg.publicHostName}.locations = imageLocations;
      };
    };

    services.aurral = {
      enable = true;
      dataDir = cfg.stateDir;
      port = model.port;
      user = model.user;
      group = model.user;
      directories = [ model.flowDir ];
      environment = {
        DOWNLOAD_FOLDER = model.flowDir;
        TRUST_PROXY = "2";
        AUTH_PROXY_HEADER = "x-forwarded-user";
        AUTH_PROXY_ADMIN_USERS = lib.concatStringsSep "," adminUsers;
        AUTH_PROXY_TRUSTED_IPS = "127.0.0.1,::1";
        DISABLE_LOCAL_AUTH = "true";
      };
    };

    systemd.services.aurral.serviceConfig.BindReadOnlyPaths = cfg.libraryRoots;
  };
}
