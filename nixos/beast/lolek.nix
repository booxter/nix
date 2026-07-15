{
  config,
  hostInventory,
  hostname,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  hostSpec = hostInventory.nixosHostSpecsByName.${hostname};
  lolekMetricsInternalPort = 19568;
  lolekMetricsMtlsPort = 9568;
in
{
  imports = [
    inputs.lolek.nixosModules.default
  ];

  sops.secrets."lolek/botToken" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.secrets."lolek/galleryDlCookies" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.secrets."lolek/telegramBotApi/apiId" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.secrets."lolek/telegramBotApi/apiHash" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
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
    package = pkgs.lolek;
    botTokenFile = config.sops.secrets."lolek/botToken".path;
    maxConcurrentDownloads = 4;
    maxConcurrentDownloadsPerChat = 2;
    postSourceCaption = true;
    postRequesterCaption = true;
    galleryDownloadEnabled = true;
    environment = {
      LOLEK_GALLERY_DL_COOKIES_FILE = config.sops.secrets."lolek/galleryDlCookies".path;
      LOLEK_MAX_GALLERY_MEDIA = "20";
      # TODO: Use a first-class upstream module option once lolek exposes one.
      LOLEK_YT_DLP_COOKIES_FILE = config.sops.secrets."lolek/galleryDlCookies".path;
    };
    hardwareAcceleration.backend = "qsv";
    hardwareAcceleration.device = hostSpec.hardware.igpu.renderDevice;
    metrics = {
      enable = true;
      port = lolekMetricsInternalPort;
    };
    localTelegramBotApi = {
      enable = true;
      environmentFile = config.sops.templates."lolek-telegram-bot-api.env".path;
      verbosity = 1;
    };
  };

  host.observability.client.prometheusMtlsEndpoints.lolek = {
    enable = true;
    port = lolekMetricsMtlsPort;
    upstream = "http://127.0.0.1:${toString lolekMetricsInternalPort}/metrics";
  };

  systemd.services.lolek = {
    # Let the application use its runtime default until the upstream module
    # stops exporting a duplicate allowlist by default.
    # https://github.com/dziaineka/lolek/pull/12
    environment.LOLEK_ALLOWED_URLS_REGEX = lib.mkForce null;
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  systemd.services.lolek-telegram-bot-api = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
