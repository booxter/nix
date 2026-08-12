{
  config,
  lib,
  pkgs,
  ...
}:
let
  pkiRootCaPath = config.host.pki.rootCaCertificate;
  transmissionCommon = pkgs.callPackage ../../srvarr/pkgs/transmission-common { };
  defaultPackage = pkgs.callPackage ./pkgs/controller {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit transmissionCommon;
  };
in
{
  imports = [
    ./assertions.nix
    ./config.nix
  ];

  options.services.adaptive-upload-policy = {
    enable = lib.mkEnableOption "Jellyfin-aware adaptive upload policy";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Adaptive upload controller package.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "adaptive-upload-policy";
      description = "User account used by the adaptive upload services.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "adaptive-upload-policy";
      description = "Group used by the adaptive upload services.";
    };

    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/adaptive-upload-policy/state.json";
      description = "Shared policy state file.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Polling interval used by the decider and appliers.";
    };

    maxStateAgeSeconds = lib.mkOption {
      type = with lib.types; nullOr ints.positive;
      default = null;
      description = "Maximum accepted state age, or null for three polling intervals.";
    };

    fallbackRateMbit = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Conservative upload rate used when policy state is unavailable.";
    };

    policy = {
      idleRateMbit = lib.mkOption {
        type = lib.types.ints.positive;
        default = 25;
        description = "Upload rate allowed when no external streams are active.";
      };

      minimumRateMbit = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "Minimum upload rate while external streams are active.";
      };

      relaxationHoldSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 90;
        description = "Stable period required before relaxing an upload limit.";
      };
    };

    source.jellyfin = {
      exporterUrl = lib.mkOption {
        type = lib.types.str;
        description = "Jellyfin exporter metrics URL.";
      };

      requestTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Jellyfin exporter request timeout.";
      };

      mediaTypes = lib.mkOption {
        type = with lib.types; nonEmptyListOf str;
        default = [
          "audio"
          "audiobook"
          "episode"
          "movie"
          "musicvideo"
          "trailer"
          "video"
        ];
        description = "Jellyfin media types included in upload budgeting.";
      };

      mtls = {
        enable = lib.mkEnableOption "mTLS authentication to the Jellyfin exporter";

        caFile = lib.mkOption {
          type = lib.types.path;
          default = pkiRootCaPath;
          description = "CA certificate used to verify the Jellyfin exporter.";
        };

        certificateFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Client certificate used to authenticate to the Jellyfin exporter.";
        };

        keyFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Client private key used to authenticate to the Jellyfin exporter.";
        };

        dependencyUnits = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Units that must start before the mTLS credentials are available.";
        };
      };
    };

    outputs.transmission = {
      enable = lib.mkEnableOption "Transmission upload-limit application";

      rpcUrl = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Transmission RPC URL, or null to use the local NixOS service.";
      };

      requestTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Transmission RPC request timeout.";
      };

      headroomPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 95;
        description = "Percentage of the policy target assigned to Transmission.";
      };
    };

    outputs.qos = {
      enable = lib.mkEnableOption "host.qos runtime-rate application";

      profile = lib.mkOption {
        type = lib.types.str;
        default = "wan";
        description = "host.qos interface profile to update.";
      };

      limit = lib.mkOption {
        type = lib.types.str;
        description = "Egress limit within the selected host.qos profile.";
      };
    };

    metrics = {
      enable = lib.mkEnableOption "Prometheus node-exporter textfile metrics" // {
        default = true;
      };

      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/prometheus-node-exporter-textfile";
        description = "Prometheus node-exporter textfile directory.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "adaptive-upload-policy.prom";
        description = "Prometheus textfile name.";
      };
    };
  };
}
