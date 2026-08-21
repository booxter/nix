{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.host.motion-captcha-bot;
in
{
  imports = [ inputs.motion-captcha-bot.nixosModules.default ];

  options.host.motion-captcha-bot.enable = lib.mkEnableOption "motion-readable Telegram captcha bot";

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      "motion-captcha-bot/botToken" = { };
      "motion-captcha-bot/allowedChatIds" = { };
    };

    sops.templates."motion-captcha-bot.env" = {
      mode = "0400";
      content = ''
        BOT_TOKEN=${config.sops.placeholder."motion-captcha-bot/botToken"}
        ALLOWED_CHAT_IDS=${config.sops.placeholder."motion-captcha-bot/allowedChatIds"}
      '';
      restartUnits = [ "motion-captcha-bot.service" ];
    };

    services.motion-captcha-bot = {
      enable = true;
      environmentFile = config.sops.templates."motion-captcha-bot.env".path;
    };

    systemd.services.motion-captcha-bot = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };

    host.autoUpgrade.claims.motion-captcha-bot.reboot.cadence = "weekly";
  };
}
