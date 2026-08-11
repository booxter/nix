{
  config,
  lib,
  ...
}:
let
  cfg = config.host.lolek;
  render = config.host.hardware.gpu.render;
  galleryCookiesSecret = config.sops.secrets."lolek/galleryDlCookies";
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets = {
      "lolek/botToken" = {
        owner = "lolek";
        group = "lolek";
        mode = "0400";
      };

      "lolek/galleryDlCookies" = {
        owner = "lolek";
        group = "lolek";
        mode = "0400";
      };

      "lolek/telegramBotApi/apiId" = {
        owner = "lolek";
        group = "lolek";
        mode = "0400";
      };

      "lolek/telegramBotApi/apiHash" = {
        owner = "lolek";
        group = "lolek";
        mode = "0400";
      };
    };

    sops.templates."lolek-telegram-bot-api.env" = {
      owner = "lolek";
      group = "lolek";
      mode = "0400";
      content = ''
        TELEGRAM_API_ID=${config.sops.placeholder."lolek/telegramBotApi/apiId"}
        TELEGRAM_API_HASH=${config.sops.placeholder."lolek/telegramBotApi/apiHash"}
      '';
    };

    services.lolek = {
      enable = true;
      package = cfg.package;
      botTokenFile = config.sops.secrets."lolek/botToken".path;
      maxConcurrentDownloads = 4;
      maxConcurrentDownloadsPerChat = 2;
      postSourceCaption = true;
      postRequesterCaption = true;
      galleryDownloadEnabled = true;
      environment = {
        LOLEK_GALLERY_DL_COOKIES_FILE = galleryCookiesSecret.path;
        LOLEK_MAX_GALLERY_MEDIA = "20";
        # TODO: Use a first-class upstream module option once lolek exposes one.
        LOLEK_YT_DLP_COOKIES_FILE = galleryCookiesSecret.path;
      };
      hardwareAcceleration = lib.mkIf (render.vendor == "intel" && render.device != null) {
        backend = "qsv";
        device = render.device;
      };
      metrics = {
        enable = true;
        port = cfg.metrics.internalPort;
      };
      localTelegramBotApi = {
        enable = true;
        environmentFile = config.sops.templates."lolek-telegram-bot-api.env".path;
        verbosity = 1;
      };
    };

    host.observability.prometheusEndpoints.lolek = {
      enable = true;
      port = cfg.metrics.port;
      upstream = "http://127.0.0.1:${toString cfg.metrics.internalPort}/metrics";
      scrape = {
        enable = true;
        profile = "application";
        component = "lolek";
        service = "lolek";
      };
    };

    systemd.services.lolek = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };

    systemd.services.lolek-telegram-bot-api = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
