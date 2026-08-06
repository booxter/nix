{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.qos;
  package = pkgs.callPackage ./pkgs/qosctl { };
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
  rateBits = rateMbit: builtins.floor (rateMbit * 1000 * 1000);
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
  profileNames = builtins.attrNames cfg.interfaces;
  profileData = builtins.mapAttrs (
    profileName: profile:
    let
      limitNames = builtins.attrNames profile.limits;
      egressNames = builtins.filter (name: profile.limits.${name}.direction == "egress") limitNames;
      ingressNames = builtins.filter (name: profile.limits.${name}.direction == "ingress") limitNames;
      classMinors = builtins.listToAttrs (
        lib.imap0 (index: name: {
          inherit name;
          value = 16 + index;
        }) egressNames
      );
      ifbInterfaces = builtins.listToAttrs (
        lib.imap0 (index: name: {
          inherit name;
          value = "ifb-qos${toString index}";
        }) ingressNames
      );
      limits = map (
        name:
        let
          limit = profile.limits.${name};
        in
        {
          inherit name;
          inherit (limit) direction;
          rateBits = rateBits limit.rateMbit;
          queue =
            if limit.queue != null then
              limit.queue
            else if limit.direction == "ingress" then
              "cake"
            else
              "fq_codel";
          classMinor = classMinors.${name} or 0;
          ifbInterface = ifbInterfaces.${name} or "";
          match = {
            inherit (limit.match)
              family
              protocol
              sourceAddress
              destinationAddress
              sourcePort
              destinationPort
              users
              ;
          };
        }
      ) limitNames;
      configFile = (pkgs.formats.json { }).generate "qos-${profileName}.json" {
        profile = profileName;
        interface = profile.device;
        nftTable = "qos_${profileName}";
        linkRateBits = rateBits profile.linkRateMbit;
        inherit limits;
      };
    in
    {
      inherit
        classMinors
        configFile
        ifbInterfaces
        ;
    }
  ) cfg.interfaces;
  command =
    profileName: action:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      "--config"
      profileData.${profileName}.configFile
      action
    ];
  hasIngress = lib.any (profileName: profileData.${profileName}.ifbInterfaces != { }) profileNames;
in
{
  options.host.qos = {
    interfaces = lib.mkOption {
      type = lib.types.attrsOf interfaceType;
      default = { };
      description = "Traffic limits grouped by owned network interface.";
    };

    classIds = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf str);
      readOnly = true;
      internal = true;
      description = "Derived tc class IDs for egress limits.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "^[A-Za-z0-9_]+$" name != null) profileNames;
        message = "host.qos.interfaces names may contain only letters, digits, and underscores";
      }
      {
        assertion =
          let
            devices = map (name: cfg.interfaces.${name}.device) profileNames;
          in
          builtins.length devices == builtins.length (lib.unique devices);
        message = "each host.qos.interfaces profile must own a distinct device";
      }
      {
        assertion = lib.all (profileName: cfg.interfaces.${profileName}.limits != { }) profileNames;
        message = "each host.qos.interfaces profile must define at least one limit";
      }
    ];

    host.qos.classIds = builtins.mapAttrs (
      _: data: builtins.mapAttrs (_: minor: "1:${lib.toLower (lib.toHexString minor)}") data.classMinors
    ) profileData;

    boot.kernelModules = lib.optional hasIngress "ifb";

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
