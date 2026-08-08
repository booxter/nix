{
  config,
  hostInventory,
  hostSpec,
  lib,
  utils,
  ...
}:
let
  nfsPort = 2049;
  clientMounts = config.host.nfs.mounts;
  qosLimits = config.host.nfs.qosLimits;
  bandwidthTargets = config.host.network.bandwidthTargets;
  nfsMountOptions = [
    "nfsvers=4"
    "hard"
    "nofail"
    "_netdev"
    "noatime"
    "x-systemd.automount"
    "x-systemd.idle-timeout=0"
    "x-systemd.mount-timeout=30s"
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
  ];
  exportFor =
    name: hostInventory.storage.nfs.exports.${name} or (throw "unknown NFS export '${name}'");
  mountFileSystems = lib.mapAttrs' (
    name: mountPoint:
    let
      export = exportFor name;
      serverAddress = hostInventory.toNixosHostIpv4Address export.server;
    in
    lib.nameValuePair mountPoint {
      device = "${serverAddress}:${export.path}";
      fsType = "nfs";
      options = nfsMountOptions;
    }
  ) clientMounts;
  exports = lib.filterAttrs (
    _: export: export.server == hostSpec.name
  ) hostInventory.storage.nfs.exports;
  mountedExports = lib.mapAttrs (name: _: exportFor name) clientMounts;
  validQosLimits = lib.filterAttrs (
    _: rule:
    builtins.hasAttr rule.export clientMounts && builtins.hasAttr rule.bandwidthTarget bandwidthTargets
  ) qosLimits;
  renderedQosLimits = lib.mapAttrs (
    _: rule:
    let
      export = exportFor rule.export;
      target = bandwidthTargets.${rule.bandwidthTarget};
    in
    {
      inherit (target) rateMbit;
      match = {
        protocol = "tcp";
        destinationAddress = hostInventory.toNixosHostIpv4Address export.server;
        destinationPort = nfsPort;
      };
    }
  ) validQosLimits;
  participatingExports = exports // mountedExports;
  sharedGroups = lib.mapAttrs' (
    _: export:
    lib.nameValuePair export.sharedGroup.name {
      inherit (export.sharedGroup) gid;
    }
  ) (lib.filterAttrs (_: export: export ? sharedGroup) participatingExports);
  exportPaths = map (export: export.path) (builtins.attrValues exports);
  exportMountPoints = lib.unique (
    builtins.concatMap (
      volume:
      map (mount: mount.mountPoint) (
        builtins.filter (
          mount:
          builtins.any (
            path: path == mount.mountPoint || lib.hasPrefix "${mount.mountPoint}/" path
          ) exportPaths
        ) (builtins.attrValues volume.mounts)
      )
    ) (builtins.attrValues config.host.storage.volumes)
  );
  exportMountUnits = map (
    mountPoint: "${utils.escapeSystemdPath mountPoint}.mount"
  ) exportMountPoints;
  defaultExportOptions = [
    "rw"
    "async"
    "no_subtree_check"
  ];
  anonymousIdentityOptions =
    export:
    lib.optionals (export ? anonymousIdentity) (
      let
        user = config.users.users.${export.anonymousIdentity};
        group = config.users.groups.${user.group};
      in
      [
        "anonuid=${toString user.uid}"
        "anongid=${toString group.gid}"
      ]
    );
  exportOptions =
    export:
    defaultExportOptions ++ [ "fsid=${toString export.fsid}" ] ++ anonymousIdentityOptions export;
  exportClients =
    export:
    builtins.listToAttrs (
      map (client: {
        name = hostInventory.toNixosHostIpv4Address client;
        value = exportOptions export;
      }) export.clients
    );
  renderedExports = lib.mapAttrs' (
    _: export: lib.nameValuePair export.path (exportClients export)
  ) exports;
in
{
  options.host.nfs.mounts = lib.mkOption {
    type = with lib.types; attrsOf str;
    default = { };
    description = "Local mount points keyed by NFS inventory export name.";
  };

  options.host.nfs.qosLimits = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          export = lib.mkOption {
            type = lib.types.str;
            description = "Mounted NFS inventory export to shape.";
          };

          bandwidthTarget = lib.mkOption {
            type = lib.types.str;
            description = "Realm bandwidth target applied to this NFS traffic.";
          };
        };
      }
    );
    default = { };
    description = "Named NFS client traffic limits.";
  };

  config = lib.mkMerge [
    {
      users.groups = sharedGroups;

      # All current NFS use is v4-only. NixOS enables rpcbind automatically
      # for NFS filesystems, but rpcbind is only needed by legacy NFSv3/RPC
      # helpers.
      services.rpcbind.enable = lib.mkOverride 75 false;
    }

    (lib.mkIf (exports != { }) {
      services.nfs = {
        server = {
          enable = true;
          exports = renderedExports;
        };
        settings.nfsd = {
          port = nfsPort;
          vers3 = "n";
          vers4 = "y";
        };
      };

      systemd.services.nfs-server = {
        # Pull NFS back up when a non-required storage volume mounts after the
        # initial boot transaction.
        wantedBy = exportMountUnits;
        unitConfig.RequiresMountsFor = exportMountPoints ++ exportPaths;
      };

      networking.firewall.allowedTCPPorts = [ nfsPort ];
    })

    (lib.mkIf (clientMounts != { }) {
      assertions = [
        {
          assertion =
            builtins.length (builtins.attrValues clientMounts)
            == builtins.length (lib.unique (builtins.attrValues clientMounts));
          message = "host.nfs.mounts must use unique local mount points.";
        }
      ]
      ++ lib.mapAttrsToList (name: _: {
        assertion = builtins.elem hostSpec.name (exportFor name).clients;
        message = "host ${hostSpec.name} is not an authorized client of NFS export '${name}'.";
      }) clientMounts;

      fileSystems = mountFileSystems;
      virtualisation.vmVariant.virtualisation.fileSystems = mountFileSystems;
    })

    (lib.mkIf (qosLimits != { }) {
      assertions = lib.flatten (
        lib.mapAttrsToList (
          name: rule:
          let
            target = bandwidthTargets.${rule.bandwidthTarget} or null;
          in
          [
            {
              assertion = builtins.hasAttr rule.export clientMounts;
              message = "host.nfs.qosLimits.${name} references an NFS export that is not mounted.";
            }
            {
              assertion = target != null;
              message = "host.nfs.qosLimits.${name} references an unknown bandwidth target.";
            }
            {
              assertion = target == null || (target.link == "lan" && target.direction == "egress");
              message = "host.nfs.qosLimits.${name} requires an egress LAN bandwidth target.";
            }
            {
              assertion = config.host.network.primaryInterface != null;
              message = "NFS QoS requires an inventory primary network interface.";
            }
          ]
        ) qosLimits
      );

      host.qos.interfaces.wan = {
        device = config.host.network.primaryInterface;
        limits = renderedQosLimits;
      };
    })
  ];
}
