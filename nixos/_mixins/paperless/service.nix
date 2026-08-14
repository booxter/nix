{
  config,
  lib,
  paperlessModel,
  ...
}:
let
  inherit (paperlessModel)
    bootstrapOwner
    cfg
    paperlessService
    passwordSecretName
    storagePath
    ;
in
{
  config = lib.mkIf (cfg != null) {
    services.paperless = {
      enable = true;
      address = "127.0.0.1";
      database.createLocally = true;
      domain = paperlessService.public.hostName;
      environmentFile = config.sops.templates."paperless-oidc.env".path;
      mediaDir = "${storagePath}/media";
      consumptionDir = "${storagePath}/consume";
      passwordFile = config.sops.secrets.${passwordSecretName bootstrapOwner}.path;
      settings = {
        PAPERLESS_ADMIN_USER = bootstrapOwner;
        PAPERLESS_ADMIN_MAIL = config.host.mailer.address;
        PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = false;
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
        PAPERLESS_ALLOWED_HOSTS = lib.concatStringsSep "," [
          paperlessService.public.hostName
          "paperless.${config.host.network.lanDomain}"
          "paperless.local"
          "127.0.0.1"
          "localhost"
        ];
        PAPERLESS_CSRF_TRUSTED_ORIGINS = paperlessService.public.url;
        PAPERLESS_DISABLE_REGULAR_LOGIN = false;
        PAPERLESS_CONSUMER_IGNORE_PATTERN = lib.concatStringsSep "," [
          ".DS_STORE/*"
          "desktop.ini"
        ];
        PAPERLESS_OCR_LANGUAGE = "eng";
        PAPERLESS_REDIRECT_LOGIN_TO_SSO = false;
        PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = false;
        PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS = true;
        PAPERLESS_SOCIAL_AUTO_SIGNUP = false;
      };
    };
  };
}
