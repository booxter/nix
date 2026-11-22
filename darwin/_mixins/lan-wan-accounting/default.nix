{
  config,
  lib,
  pkgs,
  ...
}:
let
  declaredInterfaces = builtins.attrNames config.host.network.interfaces;
  textfileDir = "${stateDir}/textfile";
  textfilePath = "${textfileDir}/lan-wan.prom";
  stateDir = "/var/lib/observability-lan-wan";
  serviceUser = "_observability-lan-wan";
  username = config.host.username;
  wiresharkEnabled = config.home-manager.users.${username}.host.hm.wireshark.enable;
  accessBpfGroup = "access_bpf";
  # Preserve the GID used by ChmodBPF on existing fleet hosts.
  accessBpfGid = 101;
  serviceUid = 536;
  prepareBpf = pkgs.writeShellApplication {
    name = "prepare-bpf";
    text = ''
      # BPF devices are created on demand. Prepare them before granting access
      # so unprivileged captures can open more than the initial device.
      max_devices=$(/usr/sbin/sysctl -n debug.bpf_maxdevices)
      for ((index = 0; index < max_devices; index++)); do
        # An existing capture can hold a device open exclusively.
        : 2>/dev/null < "/dev/bpf$index" || true
      done

      /usr/bin/chgrp ${accessBpfGroup} /dev/bpf*
      /bin/chmod 0660 /dev/bpf*
    '';
  };
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
      system.tmpfiles.settings.lan-wan = lib.genAttrs [ stateDir textfileDir ] (_: {
        d = {
          mode = "0755";
          user = serviceUser;
          group = accessBpfGroup;
        };
      });

      assertions = [
        {
          assertion = declaredInterfaces != [ ];
          message = "Darwin LAN/WAN accounting requires at least one declared network interface";
        }
      ];

      ids.uids.${serviceUser} = serviceUid;
      ids.gids.${accessBpfGroup} = accessBpfGid;

      users.groups.${accessBpfGroup} = {
        gid = config.ids.gids.${accessBpfGroup};
        members = lib.optional wiresharkEnabled username;
      };
      users.knownGroups = [ accessBpfGroup ];

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

      # The group exists now; prepare devices before tmpfiles and services.
      system.activationScripts.users.text = lib.mkOrder 1400 (lib.getExe prepareBpf);

      # devfs permissions reset at boot. The capture daemon retries until ready.
      launchd.daemons.bpf-permissions = {
        command = lib.getExe prepareBpf;
        serviceConfig = {
          RunAtLoad = true;
          ProcessType = "Background";
          StandardOutPath = "/var/log/nix-darwin/bpf-permissions.log";
          StandardErrorPath = "/var/log/nix-darwin/bpf-permissions.log";
        };
      };

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
