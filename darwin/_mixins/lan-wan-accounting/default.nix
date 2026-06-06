{
  config,
  hostname,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.lanWan;
  hostSpec = hostInventory.darwinHosts.${hostname};
  nodeCfg = config.services.prometheus.exporters.node;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  textfilePath = "${textfileDir}/lan-wan.prom";
  stateDir = "/var/lib/observability-lan-wan";
  serviceUser = "_observability-lan-wan";
  # macOS exposes /dev/bpf* as root:access_bpf 0660. Make this the service
  # account's primary group instead of running the capture daemon as root.
  accessBpfGroup = "access_bpf";
  accessBpfGid = 101;
  serviceUid = 536;
  lanWanPackage = pkgs.darwin-lan-wan-bpf;
  nodeExporterArgs = lib.escapeShellArgs (
    [
      "--web.listen-address"
      "${nodeCfg.listenAddress}:${toString nodeCfg.port}"
    ]
    ++ map (collector: "--collector.${collector}") nodeCfg.enabledCollectors
    ++ map (collector: "--no-collector.${collector}") nodeCfg.disabledCollectors
    ++ nodeCfg.extraFlags
  );
  programArguments = [
    (lib.getExe cfg.package)
    "-i"
    cfg.interface
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
  ++ [
    "--textfile"
    textfilePath
  ];
in
{
  options.host.observability.lanWan = {
    enable = lib.mkEnableOption "LAN/WAN traffic accounting for Prometheus on Darwin";

    package = lib.mkOption {
      type = lib.types.package;
      default = lanWanPackage;
      description = "Package providing the Darwin LAN/WAN BPF accounting daemon.";
    };

    lanSubnets = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ hostInventory.site.lan.cidr ];
      description = "IPv4 subnets that should be treated as LAN traffic.";
    };

    lanSubnets6 = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "fe80::/10" ];
      description = "IPv6 subnets that should be treated as LAN traffic.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = hostSpec.mainInterface or "en0";
      example = "en0";
      description = "Primary network interface to classify traffic on.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = "How often to refresh the node-exporter textfile metrics.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.prometheus.exporters.node = {
      extraFlags = [
        "--collector.textfile"
        "--collector.textfile.directory=${textfileDir}"
      ];
    };

    # Work around nix-darwin node-exporter flag joining until
    # https://github.com/nix-darwin/nix-darwin/pull/1739 lands.
    launchd.daemons.prometheus-node-exporter.serviceConfig.ProgramArguments = lib.mkForce [
      "/bin/sh"
      "-c"
      "/bin/wait4path /nix/store && exec ${lib.getExe nodeCfg.package} ${nodeExporterArgs}"
    ];

    ids.uids.${serviceUser} = serviceUid;

    users.users.${serviceUser} = {
      uid = config.ids.uids.${serviceUser};
      gid = accessBpfGid;
      home = stateDir;
      createHome = true;
      shell = "/usr/bin/false";
      description = "System user for Darwin LAN/WAN BPF accounting";
    };
    users.knownUsers = [ serviceUser ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
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

      mkdir -p ${textfileDir} ${stateDir}
      chown ${serviceUser}:${accessBpfGroup} ${textfileDir} ${stateDir}
      chmod 0755 ${textfileDir} ${stateDir}
    '';

    launchd.daemons.observability-lan-wan-accounting = {
      serviceConfig = {
        ProgramArguments = programArguments;
        RunAtLoad = true;
        KeepAlive = true;
        UserName = serviceUser;
        GroupName = accessBpfGroup;
        ProcessType = "Background";
        LowPriorityIO = true;
        StandardOutPath = "${stateDir}/lan-wan.log";
        StandardErrorPath = "${stateDir}/lan-wan.log";
      };
    };
  };
}
