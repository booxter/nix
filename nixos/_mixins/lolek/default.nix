{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.lolek;
  hostVideoAcceleration = if config.host.gpu == null then null else config.host.gpu.videoAcceleration;
  lolekSecret = {
    owner = cfg.user;
    group = cfg.group;
    mode = "0400";
  };
  telegramBotApiEnvironment = "lolek-telegram-bot-api.env";
in
{
  imports = [
    inputs.lolek.nixosModules.default
  ];

  options.services.lolek = {
    hardwareAcceleration.useHost = lib.mkEnableOption "the host video acceleration capability";

    metrics.mtlsPort = lib.mkOption {
      type = lib.types.port;
      default = 9568;
      description = "LAN-visible port for the mTLS-protected metrics endpoint.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.lolek = {
          package = lib.mkDefault pkgs.lolek;
          botTokenFile = config.sops.secrets."lolek/botToken".path;
          metrics.port = lib.mkDefault 19568;
          environment = {
            LOLEK_GALLERY_DL_COOKIES_FILE = config.sops.secrets."lolek/galleryDlCookies".path;
            # TODO: Use a first-class upstream module option once Lolek exposes one.
            LOLEK_YT_DLP_COOKIES_FILE = config.sops.secrets."lolek/galleryDlCookies".path;
          };
        };

        sops.secrets = {
          "lolek/botToken" = lolekSecret;
          "lolek/galleryDlCookies" = lolekSecret;
        };

        systemd.services.lolek = {
          wants = [ "sops-install-secrets.service" ];
          after = [ "sops-install-secrets.service" ];
        };
      }

      (lib.mkIf cfg.hardwareAcceleration.useHost {
        assertions = [
          {
            assertion = hostVideoAcceleration != null;
            message = "services.lolek.hardwareAcceleration.useHost requires host.gpu.videoAcceleration.";
          }
        ];

        services.lolek.hardwareAcceleration = lib.mkIf (hostVideoAcceleration != null) {
          backend = lib.mkDefault hostVideoAcceleration.backend;
          device = lib.mkDefault hostVideoAcceleration.device;
        };
      })

      (lib.mkIf cfg.metrics.enable {
        host.observability.prometheusEndpoints.lolek = {
          enable = true;
          port = cfg.metrics.mtlsPort;
          upstream = "http://${cfg.metrics.listenAddress}:${toString cfg.metrics.port}/metrics";
        };
      })

      (lib.mkIf cfg.localTelegramBotApi.enable {
        services.lolek.localTelegramBotApi.environmentFile =
          config.sops.templates.${telegramBotApiEnvironment}.path;

        sops = {
          secrets = {
            "lolek/telegramBotApi/apiId" = lolekSecret;
            "lolek/telegramBotApi/apiHash" = lolekSecret;
          };
          templates.${telegramBotApiEnvironment} = lolekSecret // {
            content = ''
              TELEGRAM_API_ID=${config.sops.placeholder."lolek/telegramBotApi/apiId"}
              TELEGRAM_API_HASH=${config.sops.placeholder."lolek/telegramBotApi/apiHash"}
            '';
          };
        };

        systemd.services.lolek-telegram-bot-api = {
          wants = [ "sops-install-secrets.service" ];
          after = [ "sops-install-secrets.service" ];
        };
      })
    ]
  );
}
