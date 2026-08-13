{
  config,
  lib,
  pkgs,
  ...
}:
let
  transmissionCommon = pkgs.callPackage ../transmission/pkgs/common { };
  defaultPackage = pkgs.callPackage ./pkgs/controller {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit transmissionCommon;
  };
  downloadClientDestinationType = lib.types.submodule {
    options = {
      client = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Registered host.downloads client receiving adaptive upload decisions.";
      };

      headroomPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 95;
        description = "Percentage of the policy target assigned to the download client.";
      };
    };
  };
  qosDestinationType = lib.types.submodule {
    options = {
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

  options.host.adaptiveUploadPolicy = {
    enable = lib.mkEnableOption "Jellyfin-aware adaptive upload policy";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      internal = true;
    };

    fallbackRateMbit = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Conservative upload rate used when policy state is unavailable.";
    };

    source.jellyfin = {
      host = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "NixOS host exporting Jellyfin playback metrics.";
      };

      exporterUrl = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        internal = true;
        description = "Direct Jellyfin exporter URL used by isolated module tests.";
      };
    };

    destinations = {
      downloadClients = lib.mkOption {
        type = lib.types.attrsOf downloadClientDestinationType;
        default = { };
        description = "Registered download clients receiving adaptive upload decisions.";
      };

      qos = lib.mkOption {
        type = lib.types.attrsOf qosDestinationType;
        default = { };
        description = "Network traffic classes receiving adaptive upload decisions.";
      };
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "adaptive-upload-policy";
      readOnly = true;
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "adaptive-upload-policy";
      readOnly = true;
      internal = true;
    };

    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/adaptive-upload-policy/state.json";
      readOnly = true;
      internal = true;
    };
  };
}
