{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.wireguardQos;
  package = pkgs.callPackage ./pkgs/wireguard-qos { };
  rateBits = rateMbit: rateMbit * 1000 * 1000;
  qosConfig = (pkgs.formats.json { }).generate "wireguard-qos.json" {
    interface = cfg.interface;
    routeProbe = cfg.routeProbe;
    outerRateBits = rateBits cfg.outerRateMbit;
    wireguard = {
      port = cfg.port;
      uploadRateBits = rateBits cfg.uploadRateMbit;
      downloadRateBits = if cfg.downloadRateMbit == null then null else rateBits cfg.downloadRateMbit;
      egressPort = cfg.egressPort;
      ifbInterface = cfg.ifbInterface;
    };
    nfs =
      if cfg.nfs == null then
        null
      else
        {
          inherit (cfg.nfs) address port;
          rateBits = rateBits cfg.nfs.rateMbit;
        };
  };
  command =
    action:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      "--config"
      qosConfig
      action
    ];
in
{
  options.host.wireguardQos = {
    enable = lib.mkEnableOption "native WireGuard traffic shaping";

    interface = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Interface to shape, or null to resolve it through routeProbe.";
    };

    routeProbe = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "Destination whose route selects the interface when interface is null.";
    };

    wireguardUnit = lib.mkOption {
      type = lib.types.str;
      description = "WireGuard systemd unit that owns the shaping lifecycle.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      description = "Outer WireGuard UDP port to classify.";
    };

    egressPort = lib.mkOption {
      type = lib.types.enum [
        "source"
        "destination"
      ];
      description = "Whether outbound WireGuard traffic is selected by source or destination port.";
    };

    outerRateMbit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10000;
      description = "Nominal outer link rate in Mbit/s.";
    };

    uploadRateMbit = lib.mkOption {
      type = lib.types.ints.positive;
      description = "WireGuard upload ceiling in Mbit/s.";
    };

    downloadRateMbit = lib.mkOption {
      type = with lib.types; nullOr ints.positive;
      default = null;
      description = "Optional WireGuard download ceiling in Mbit/s through an IFB.";
    };

    ifbInterface = lib.mkOption {
      type = lib.types.str;
      default = "ifb-wg";
      description = "IFB interface used when download shaping is enabled.";
    };

    nfs = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            address = lib.mkOption {
              type = str;
              description = "NFS server address to rate-limit.";
            };
            port = lib.mkOption {
              type = port;
              description = "NFS server TCP port.";
            };
            rateMbit = lib.mkOption {
              type = ints.positive;
              description = "NFS upload ceiling in Mbit/s.";
            };
          };
        });
      default = null;
      description = "Optional NFS egress rate limit.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = lib.optional (cfg.downloadRateMbit != null) "ifb";

    assertions = [
      {
        assertion = cfg.uploadRateMbit <= cfg.outerRateMbit;
        message = "host.wireguardQos.uploadRateMbit cannot exceed outerRateMbit";
      }
      {
        assertion = cfg.nfs == null || cfg.nfs.rateMbit <= cfg.outerRateMbit;
        message = "host.wireguardQos.nfs.rateMbit cannot exceed outerRateMbit";
      }
    ];

    systemd.services.wg-qos = {
      description = "Shape outer WireGuard traffic";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        cfg.wireguardUnit
      ];
      bindsTo = [ cfg.wireguardUnit ];
      partOf = [ cfg.wireguardUnit ];
      restartTriggers = [ qosConfig ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = command "start";
        ExecStop = command "stop";
      };
    };
  };
}
