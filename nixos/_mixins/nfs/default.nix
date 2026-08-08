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
  exports = lib.filterAttrs (
    _: export: export.server == hostSpec.name
  ) hostInventory.storage.nfs.exports;
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
  config = lib.mkIf (exports != { }) {
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
  };
}
