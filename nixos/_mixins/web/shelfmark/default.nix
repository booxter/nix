{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.services.shelfmark;
  hostCfg = config.host.shelfmark;
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  shelfmarkAccount = hostInventory.serviceAccounts.shelfmark;
  shelfmarkService = hostInventory.servicesById.shelfmark;
  instance = shelfmarkService.instances.${hostname} or { };
  shelfmarkSso = hostInventory.sso.applications.shelfmark;
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaGroup = mediaExport.sharedGroup;
  isMediaServer = mediaExport.server == hostname;
  stateDir = cfg.dataDir;
  mediaDir = cfg.mediaDir;
  booksDir = "${mediaDir}/${mediaExport.layout.library.books}";
  user = "shelfmark";
  oidcClient = config.host.sso.oidc.clients.shelfmark;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  imports = [ ./ebook-converter.nix ];

  options = {
    host.shelfmark.enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname shelfmarkService;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns Shelfmark to this host.";
    };

    services.shelfmark = {
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/shelfmark";
        description = "Directory containing Shelfmark state.";
      };

      mediaDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/shelfmark-media";
        description = "Local mount point for shared media storage.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir && instance ? mediaDir;
          message = "The Shelfmark inventory instance must define dataDir and mediaDir.";
        }
        {
          assertion = builtins.elem hostname mediaExport.clients;
          message = "The Shelfmark host must be an authorized media NFS client.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Shelfmark host must be a declared backup client.";
        }
      ];

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = instance.mediaDir;
      };

      host.sso.oidc.registrations.shelfmark = {
        displayName = "Shelfmark";
        originUrls = [ "${shelfmarkService.url}/api/auth/oidc/callback" ];
        originLanding = "${shelfmarkService.url}/";
        scopeMaps = {
          ${shelfmarkSso.adminGroup} = oidcScopes ++ [ "media_groups" ];
          ${shelfmarkSso.userGroup} = oidcScopes ++ [ "media_groups" ];
        };
        claimMaps.media_groups.valuesByGroup = {
          ${shelfmarkSso.adminGroup} = [ shelfmarkSso.adminGroup ];
          ${shelfmarkSso.userGroup} = [ shelfmarkSso.userGroup ];
        };
        secret = {
          sopsKey = "shelfmark/oidc/client_secret";
          name = "shelfmark/oidc/client_secret";
          restartUnits = [ "shelfmark.service" ];
        };
      };

      sops.templates."shelfmark-oidc.env" = {
        owner = user;
        group = mediaGroup.name;
        mode = "0400";
        content = ''
          OIDC_CLIENT_SECRET=${oidcClient.secret.placeholder}
        '';
        restartUnits = [ "shelfmark.service" ];
      };

      services.shelfmark = {
        enable = true;
        dataDir = instance.dataDir;
        mediaDir = instance.mediaDir;
        ebookConverter.enable = true;
        environment = {
          AUTH_METHOD = "oidc";
          CONFIG_DIR = stateDir;
          CUSTOM_SCRIPT = "${cfg.ebookConverter.package}/bin/shelfmark-ebook-converter-hook";
          CUSTOM_SCRIPT_JSON_PAYLOAD = "true";
          CUSTOM_SCRIPT_PATH_MODE = "absolute";
          DISABLE_LOCAL_AUTH = "true";
          EBOOK_CONVERTER_LIBRARY_ROOT = booksDir;
          EBOOK_CONVERTER_STATE_DIR = cfg.ebookConverter.stateDir;
          FLASK_HOST = "127.0.0.1";
          HIDE_LOCAL_AUTH = "true";
          OIDC_ADMIN_GROUP = shelfmarkSso.adminGroup;
          OIDC_AUTO_PROVISION = "true";
          OIDC_BUTTON_LABEL = "SSO";
          OIDC_CLIENT_ID = oidcClient.clientId;
          OIDC_DISCOVERY_URL = oidcClient.discoveryUrl;
          OIDC_GROUP_CLAIM = "media_groups";
          OIDC_SCOPES = lib.concatStringsSep "," (oidcScopes ++ [ "media_groups" ]);
          OIDC_USE_ADMIN_GROUP = "true";
          SESSION_COOKIE_SECURE = "true";
        };
      };

      systemd.tmpfiles.rules = [
        "d '${stateDir}' 0700 ${user} root - -"
      ];

      systemd.services.shelfmark = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        unitConfig.RequiresMountsFor = [ mediaDir ];
        serviceConfig = {
          EnvironmentFile = config.sops.templates."shelfmark-oidc.env".path;
          Group = mediaGroup.name;
          ReadWritePaths = [
            stateDir
            cfg.ebookConverter.stateDir
            mediaDir
          ];
          StateDirectory = lib.mkForce "";
          UMask = lib.mkForce "0002";
          User = user;
        };
      };

      users.users.${user} = {
        group = mediaGroup.name;
        home = "/var/empty";
        isSystemUser = true;
        uid = shelfmarkAccount.uid;
      };

      host.internalService.services.shelfmark = {
        enable = true;
        upstream = "http://127.0.0.1:${toString cfg.environment.FLASK_PORT}";
        publicAliases = [ shelfmarkService.publicHost ];
        mtls.enable = true;
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host ${shelfmarkService.publicHost};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host ${shelfmarkService.publicHost};
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };

      host.backups.jobs.${backupJob}.paths = [ stateDir ];
    })
  ];
}
