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

  config = lib.mkMerge [
    { users.groups = sharedGroups; }

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
  ];
}
