{
  config,
  hostInventory,
  hostname,
  inputs,
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

  sops.secrets.lolekTelegramBotApiApiId = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.secrets.lolekTelegramBotApiApiHash = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.templates."lolek-telegram-bot-api.env" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
    content = ''
      TELEGRAM_API_ID=${config.sops.placeholder.lolekTelegramBotApiApiId}
      TELEGRAM_API_HASH=${config.sops.placeholder.lolekTelegramBotApiApiHash}
    '';
  };

  services.lolek = {
    enable = true;
    botTokenFile = config.sops.secrets."lolek/botToken".path;
    maxConcurrentDownloads = 4;
    maxConcurrentDownloadsPerChat = 2;
    postSourceCaption = true;
    postRequesterCaption = true;
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
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  systemd.services.lolek-telegram-bot-api = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
