{
  config,
  lib,
  pkgs,
  ...
}:
let
  declaredInterfaces = builtins.attrNames config.host.network.interfaces;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  textfilePath = "${textfileDir}/lan-wan.prom";
  stateDir = "/var/lib/observability-lan-wan";
  serviceUser = "_observability-lan-wan";
  # macOS exposes /dev/bpf* as root:access_bpf 0660. Make this the service
  # account's primary group instead of running the capture daemon as root.
  accessBpfGroup = "access_bpf";
  accessBpfGid = 101;
  serviceUid = 536;
  lanWanPackage = pkgs.callPackage ./pkgs/darwin-lan-wan-bpf { };
  programArguments = [
    (lib.getExe lanWanPackage)
  ]
  ++ lib.concatMap (interface: [
    "-i"
    interface
  ]) declaredInterfaces
  ++ [
    "-p"
    "15"
    "-l"
    config.host.site.lan.cidr
    "-6"
    "fe80::/10"
    "--textfile"
    textfilePath
  ];
  command = lib.escapeShellArgs programArguments;
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = declaredInterfaces != [ ];
          message = "Darwin LAN/WAN accounting requires at least one declared network interface";
        }
      ];

      ids.uids.${serviceUser} = serviceUid;

      users.users.${serviceUser} = {
        uid = config.ids.uids.${serviceUser};
        gid = accessBpfGid;
        createHome = false;
        shell = "/usr/bin/false";
        description = "System user for Darwin LAN/WAN BPF accounting";
      };
      users.knownUsers = [ serviceUser ];

      host.launchd.logging.locations.observability-lan-wan = {
        directory = stateDir;
        collect = true;
        scope = "system";
      };

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
    }
    (lib.mkIf config.host.observability.enable {
      host.observability.nodeExporter.textfile.directories.lanWan = textfileDir;
    })
  ];
}
