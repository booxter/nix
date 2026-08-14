{
  config,
  lib,
  ...
}:
let
  transmissionDestinationType = lib.types.submodule {
    options = {
      headroomPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 95;
        description = "Percentage of the policy target assigned to the download client.";
      };
    };
  };
  qosDestinationType = lib.types.submodule {
    options = {
      limit = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Name of the host.qos limit managed by the policy.";
      };

      interface = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = config.host.network.primaryInterface;
        description = "Network interface carrying adaptively limited traffic.";
      };

      queue = lib.mkOption {
        type = lib.types.enum [
          "cake"
          "fq_codel"
        ];
        default = "cake";
        description = "Queue discipline used for adaptively limited uploads.";
      };

      match = {
        protocol = lib.mkOption {
          type = lib.types.enum [
            "tcp"
            "udp"
          ];
          default = "udp";
        };

        remotePort = lib.mkOption {
          type = lib.types.port;
          description = "Remote port identifying both directions of managed traffic.";
        };
      };

      maximumDownloadRateMbit = lib.mkOption {
        type = with lib.types; nullOr ints.positive;
        default = null;
        description = "Optional ingress ceiling paired with the adaptive upload destination.";
      };

      accountingName = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Optional LAN/WAN accounting name for this traffic.";
      };
    };
  };
in
{
  imports = [
    ./assertions.nix
    ./config.nix
  ];

  options.host.adaptiveUploadPolicy = lib.mkOption {
    type =
      with lib.types;
      nullOr (submodule {
        options = {
          fallbackRateMbit = lib.mkOption {
            type = ints.positive;
            description = "Conservative upload rate used when policy state is unavailable.";
          };

          source.jellyfin = {
            host = lib.mkOption {
              type = nullOr nonEmptyStr;
              default = null;
              description = "NixOS host exporting Jellyfin playback metrics.";
            };

            exporterUrl = lib.mkOption {
              type = nullOr nonEmptyStr;
              default = null;
              internal = true;
              description = "Direct Jellyfin exporter URL used by isolated module tests.";
            };
          };

          destinations = {
            transmission = lib.mkOption {
              type = nullOr transmissionDestinationType;
              default = null;
              description = "Local Transmission service receiving adaptive upload decisions.";
            };

            qos = lib.mkOption {
              type = nullOr qosDestinationType;
              default = null;
              description = "Network traffic class receiving adaptive upload decisions.";
            };
          };

        };
      });
    default = null;
    description = "Jellyfin-aware adaptive upload policy.";
  };
}
