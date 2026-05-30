{
  config,
  hostInventory,
  hostname,
  inputs,
  ...
}:
let
  hostSpec = hostInventory.nixosHostSpecsByName.${hostname};
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
    botTokenFile = config.sops.secrets."lolek/botToken".path;
    hardwareAcceleration.backend = "vaapi";
    hardwareAcceleration.device = hostSpec.hardware.igpu.renderDevice;
    localTelegramBotApi = {
      enable = true;
      environmentFile = config.sops.templates."lolek-telegram-bot-api.env".path;
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
}
