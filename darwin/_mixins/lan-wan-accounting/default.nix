{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.lanWan;
  declaredInterfaces = builtins.attrNames config.host.network.interfaces;
  textfileDir = "${stateDir}/textfile";
  textfilePath = "${textfileDir}/lan-wan.prom";
  stateDir = "/var/lib/observability-lan-wan";
  serviceUser = "_observability-lan-wan";
  darwinPkgs = import ../../pkgs pkgs;
  # macOS exposes /dev/bpf* as root:access_bpf 0660. Make this the service
  # account's primary group instead of running the capture daemon as root.
  accessBpfGroup = "access_bpf";
  accessBpfGid = 101;
  serviceUid = 536;
  lanWanPackage = darwinPkgs.darwin-lan-wan-bpf;
  programArguments = [
    (lib.getExe cfg.package)
  ]
  ++ lib.concatMap (interface: [
    "-i"
    interface
  ]) cfg.interfaces
  ++ [
    "-p"
    (toString cfg.intervalSeconds)
  ]
  ++ lib.concatMap (cidr: [
    "-l"
    cidr
  ]) cfg.lanSubnets
  ++ lib.concatMap (cidr: [
    "-6"
    cidr
  ]) cfg.lanSubnets6
  ++ lib.optionals cfg.exportToNodeExporter [
    "--textfile"
    textfilePath
  ];
  command = lib.escapeShellArgs programArguments;
in
{
  options.host.observability.lanWan = {
    enable = lib.mkEnableOption "LAN/WAN traffic accounting on Darwin";

    exportToNodeExporter = lib.mkOption {
      type = lib.types.bool;
      default = config.host.observability.enable;
      description = "Whether to expose LAN/WAN accounting through node exporter's textfile collector.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = lanWanPackage;
      description = "Package providing the Darwin LAN/WAN BPF accounting daemon.";
    };

    lanSubnets = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ facts.site.lan.cidr ];
      description = "IPv4 subnets that should be treated as LAN traffic.";
    };

    lanSubnets6 = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "fe80::/10" ];
      description = "IPv6 subnets that should be treated as LAN traffic.";
    };

    interfaces = lib.mkOption {
      type = with lib.types; listOf str;
      default = declaredInterfaces;
      defaultText = lib.literalExpression "builtins.attrNames config.host.network.interfaces";
      example = [
        "en0"
        "en1"
      ];
      description = "Network interfaces to classify traffic on.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = "How often to refresh the node-exporter textfile metrics.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enable || cfg.interfaces != [ ];
          message = "host.observability.lanWan requires at least one interface";
        }
        {
          assertion = lib.all (
            interface: builtins.hasAttr interface config.host.network.interfaces
          ) cfg.interfaces;
          message = "host.observability.lanWan.interfaces must reference declared host.network.interfaces";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];

      host.observability.nodeExporter.textfile.directories.lanWan = textfileDir;

      ids.uids.${serviceUser} = serviceUid;

      users.users.${serviceUser} = {
        uid = config.ids.uids.${serviceUser};
        gid = accessBpfGid;
        createHome = false;
        shell = "/usr/bin/false";
        description = "System user for Darwin LAN/WAN BPF accounting";
      };
      users.knownUsers = [ serviceUser ];

      system.activationScripts.launchd.text = lib.mkAfter ''
        access_bpf_gid="$(/usr/bin/dscacheutil -q group -a name ${accessBpfGroup} | /usr/bin/awk '/^gid:/ { print $2; exit }')"
        if [ "$access_bpf_gid" != "${toString accessBpfGid}" ]; then
          echo "Expected ${accessBpfGroup} gid ${toString accessBpfGid}, got ''${access_bpf_gid:-missing}" >&2
          exit 1
        fi

        bpf_group="$(/usr/bin/stat -f '%Sg' /dev/bpf0)"
        bpf_mode="$(/usr/bin/stat -f '%OLp' /dev/bpf0)"
        if [ "$bpf_group" != "${accessBpfGroup}" ] || [ "$bpf_mode" != "660" ]; then
          echo "Expected /dev/bpf0 to be root:${accessBpfGroup} 660, got group=$bpf_group mode=$bpf_mode" >&2
          exit 1
        fi

        mkdir -p ${stateDir} ${textfileDir}
        chown ${serviceUser}:${accessBpfGroup} ${stateDir} ${textfileDir}
        chmod 0755 ${stateDir} ${textfileDir}
      '';

      launchd.daemons.observability-lan-wan-accounting = {
        inherit command;
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive = true;
          UserName = serviceUser;
          GroupName = accessBpfGroup;
          InitGroups = false;
          ProcessType = "Background";
          LowPriorityIO = true;
          StandardOutPath = "${stateDir}/lan-wan.log";
          StandardErrorPath = "${stateDir}/lan-wan.log";
        };
      };
    })
  ];
}
