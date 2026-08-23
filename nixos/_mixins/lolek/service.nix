{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  cfg = config.host.lolek;
  gpu = config.host.hardware.gpu;
  galleryCookiesSecret = config.sops.secrets."lolek/galleryDlCookies";
  metricsEndpoint = fleetInventory.observability.endpoints.${config.networking.hostName}.lolek;
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

      "lolek/telegramBotApi/apiId" = { };
      "lolek/telegramBotApi/apiHash" = { };
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
      maxGalleryMedia = 20;
      environment = {
        LOLEK_GALLERY_DL_COOKIES_FILE = galleryCookiesSecret.path;
        # TODO: Use a first-class upstream module option once lolek exposes one.
        LOLEK_YT_DLP_COOKIES_FILE = galleryCookiesSecret.path;
      };
      hardwareAcceleration = lib.mkIf (gpu.vendor == "intel" && gpu.renderDevice != null) {
        backend = "qsv";
        device = gpu.renderDevice;
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
      port = metricsEndpoint.port;
      upstream = "http://127.0.0.1:${toString cfg.metrics.internalPort}/metrics";
      scrape = {
        inherit (metricsEndpoint)
          component
          profile
          service
          ;
        inherit (metricsEndpoint) jobName;
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
