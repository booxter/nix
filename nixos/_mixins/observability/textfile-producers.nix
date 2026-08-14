{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.observability;
  producers = cfg.nodeExporter.textfile.periodicProducers;
  textfileDir = cfg.nodeExporter.textfile.directories.default;
  producerType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        command = lib.mkOption {
          type = with lib.types; nonEmptyListOf str;
          description = "Command and arguments used to produce Prometheus metrics.";
        };

        description = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Systemd service description.";
        };

        interval = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Interval between metrics updates.";
        };

        onBootSec = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = config.interval;
          description = "Delay before the first metrics update after boot.";
        };

        accuracySec = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Timer scheduling accuracy, or the systemd default when unset.";
        };

        randomizedDelaySec = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Random delay added to each metrics update.";
        };

        persistent = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to catch up an update missed while the host was offline.";
        };

        after = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "Units ordered before the metrics producer.";
        };

        wants = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "Units weakly required by the metrics producer.";
        };

        requires = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "Units required by the metrics producer.";
        };

        addressFamilies = lib.mkOption {
          type = with lib.types; nonEmptyListOf nonEmptyStr;
          default = [ "AF_UNIX" ];
          description = "Socket address families available to the metrics producer.";
        };
      };
    }
  );
  toService = _: producer: {
    inherit (producer)
      after
      description
      requires
      wants
      ;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = utils.escapeSystemdExecArgs producer.command;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      RestrictAddressFamilies = producer.addressFamilies;
      RestrictRealtime = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
    };
  };
  toTimer = _: producer: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = producer.onBootSec;
      OnUnitActiveSec = producer.interval;
      Persistent = producer.persistent;
    }
    // lib.optionalAttrs (producer.accuracySec != null) {
      AccuracySec = producer.accuracySec;
    }
    // lib.optionalAttrs (producer.randomizedDelaySec != null) {
      RandomizedDelaySec = producer.randomizedDelaySec;
    };
  };
in
{
  options.host.observability.nodeExporter.textfile.periodicProducers = lib.mkOption {
    type = lib.types.attrsOf producerType;
    default = { };
    internal = true;
    description = "Periodic producers for node-exporter textfile metrics.";
  };

  config = lib.mkIf (producers != { }) {
    assertions = [
      {
        assertion = cfg.enable;
        message = "node-exporter textfile producers require host.observability.enable";
      }
    ];

    systemd.services = lib.mapAttrs toService producers;
    systemd.timers = lib.mapAttrs toTimer producers;
  };
}
