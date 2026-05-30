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

  sops.secrets."lolek/telegramBotApiApiId" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.secrets."lolek/telegramBotApiApiHash" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  sops.templates."lolek-telegram-bot-api.env" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
    content = ''
      TELEGRAM_API_ID=${config.sops.placeholder."lolek/telegramBotApiApiId"}
      TELEGRAM_API_HASH=${config.sops.placeholder."lolek/telegramBotApiApiHash"}
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
