{
  config,
  hostInventory,
  lib,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  paperlessAccount = hostInventory.serviceAccounts.paperless;
  paperlessStoragePath = "/data/paperless";
  paperlessStoragePaths = builtins.mapAttrs (
    _: value: "${paperlessStoragePath}/${value}"
  ) hostInventory.storage.nfs.exports.paperless.layout;
  paperlessNfsPaths = builtins.attrValues paperlessStoragePaths;
  isLocal = hostInventory.serviceRunsOn config.networking.hostName paperlessService;
in
{
  config = lib.mkIf isLocal {
    host.nfs.mounts.paperless = paperlessStoragePath;

    services.paperless = {
      enable = true;
      address = "127.0.0.1";
      database.createLocally = true;
      domain = paperlessService.publicHost;
      mediaDir = paperlessStoragePaths.media;
      consumptionDir = paperlessStoragePaths.consume;
      passwordFile = config.sops.secrets."paperless/admin/password".path;
      settings = {
        PAPERLESS_ADMIN_USER = hostInventory.sso.administrator;
        PAPERLESS_ADMIN_MAIL = hostInventory.user.emails.personal;
        PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = false;
        PAPERLESS_ALLOWED_HOSTS = lib.concatStringsSep "," [
          paperlessService.publicHost
          "paperless.${hostInventory.site.lan.domain}"
          "paperless.local"
          "127.0.0.1"
          "localhost"
        ];
        PAPERLESS_CSRF_TRUSTED_ORIGINS = paperlessService.url;
        PAPERLESS_CONSUMER_IGNORE_PATTERN = lib.concatStringsSep "," [
          ".DS_STORE/*"
          "desktop.ini"
        ];
        PAPERLESS_OCR_LANGUAGE = hostInventory.regional.language.ocrCode;
      };
    };

    users.groups.paperless.gid = paperlessAccount.gid;
    users.users.paperless.uid = paperlessAccount.uid;

    systemd.services = {
      paperless-consumer.unitConfig.RequiresMountsFor = paperlessNfsPaths;
      paperless-scheduler.unitConfig.RequiresMountsFor = paperlessNfsPaths;
      paperless-task-queue.unitConfig.RequiresMountsFor = paperlessNfsPaths;
      paperless-web.unitConfig.RequiresMountsFor = paperlessNfsPaths;
    };

    systemd.tmpfiles.settings."10-paperless" = lib.mkForce {
      # The upstream module also creates media and consume directories. Those
      # paths live on NFS and are owned and created by the export server.
      "${config.services.paperless.dataDir}".d = {
        user = config.services.paperless.user;
        group = config.users.users.${config.services.paperless.user}.group;
      };
    };

    host.internalService.services.paperless = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.paperless.port}";
      publicAliases = [ paperlessService.publicHost ];
      mtls.enable = true;
      recommendedProxySettings = false;
      locationExtraConfig = ''
        client_max_body_size 512m;
        proxy_set_header Host ${paperlessService.publicHost};
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host ${paperlessService.publicHost};
        proxy_set_header X-Forwarded-Server $hostname;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
      '';
    };

    host.publicIngress.exports.paperless.locationExtraConfig = ''
      client_max_body_size 512m;
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    '';
  };
}
