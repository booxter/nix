{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib pkgs; };
  inherit (model) package profileData profileNames;
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
  limitType = lib.types.submodule {
    options = {
      direction = lib.mkOption {
        type = lib.types.enum [
          "egress"
          "ingress"
        ];
        default = "egress";
      };

      rateMbit = lib.mkOption {
        type = positiveNumber;
        description = "Traffic ceiling in Mbit/s.";
      };

      queue = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "cake"
            "fq_codel"
          ]
        );
        default = null;
        description = "Queue discipline, or null to select the direction default.";
      };

      match = {
        family = lib.mkOption {
          type = lib.types.enum [
            "both"
            "ipv4"
            "ipv6"
          ];
          default = "both";
        };

        protocol = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.enum [
              "tcp"
              "udp"
            ]
          );
          default = null;
        };

        sourceAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        destinationAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        sourcePort = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
        };

        destinationPort = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
        };

        users = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
        };
      };
    };
  };
  interfaceType = lib.types.submodule {
    options = {
      device = lib.mkOption {
        type = lib.types.str;
        description = "Network interface owned by this QoS profile.";
      };

      linkRateMbit = lib.mkOption {
        type = positiveNumber;
        default = 10000;
        description = "Nominal interface rate used for unclassified traffic.";
      };

      limits = lib.mkOption {
        type = lib.types.attrsOf limitType;
        default = { };
      };
    };
  };
  command =
    profileName: action:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      "--config"
      profileData.${profileName}.configFile
      action
    ];
in
{
  imports = [ ./assertions.nix ];

  options.host.qos.interfaces = lib.mkOption {
    type = lib.types.attrsOf interfaceType;
    default = { };
    description = "Traffic limits grouped by owned network interface.";
  };

  config = {
    _module.args.qosModel = model;

    boot.kernelModules = lib.optional model.hasIngress "ifb";

    systemd.services = builtins.listToAttrs (
      map (profileName: {
        name = "qos-${profileName}";
        value = {
          description = "Apply ${profileName} interface traffic limits";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          restartTriggers = [ profileData.${profileName}.configFile ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = command profileName "start";
            ExecStop = command profileName "stop";
          };
        };
      }) profileNames
    );
  };
}
