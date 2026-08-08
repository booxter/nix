{
  config,
  hostInventory,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.lolek;
  hostCfg = config.host.lolek;
  hostname = config.networking.hostName;
  lolekService = hostInventory.servicesById.lolek;
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

  options.services.lolek.metrics.mtlsPort = lib.mkOption {
    type = lib.types.port;
    default = 9568;
    description = "LAN-visible port for the mTLS-protected metrics endpoint.";
  };

  options.host.lolek.enable = lib.mkOption {
    type = lib.types.bool;
    default = hostInventory.serviceRunsOn hostname lolekService;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns the Lolek service to this host.";
  };

  config = lib.mkMerge [
    {
      services.lolek.enable = hostCfg.enable;
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          services.lolek = {
            package = lib.mkDefault pkgs.lolek;
            botTokenFile = config.sops.secrets."lolek/botToken".path;
            maxConcurrentDownloads = lib.mkDefault 4;
            maxConcurrentDownloadsPerChat = lib.mkDefault 2;
            postSourceCaption = lib.mkDefault true;
            postRequesterCaption = lib.mkDefault true;
            galleryDownloadEnabled = lib.mkDefault true;
            maxGalleryMedia = lib.mkDefault 20;
            hardwareAcceleration = lib.mkIf (hostVideoAcceleration != null) {
              backend = lib.mkDefault hostVideoAcceleration.backend;
              device = lib.mkDefault hostVideoAcceleration.device;
            };
            metrics.enable = lib.mkDefault true;
            metrics.port = lib.mkDefault 19568;
            localTelegramBotApi = {
              enable = lib.mkDefault true;
              verbosity = lib.mkDefault 1;
            };
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
    ))
  ];
}
