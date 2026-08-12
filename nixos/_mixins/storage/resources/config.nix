{
  config,
  lib,
  outputs,
  utils,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  fleetNetwork = import ../../../_lib/fleet-host-network.nix { inherit config outputs; };
  remoteClaims = lib.filterAttrs (_: claim: !claim.local) model.localClaims;
  mountOptions = [
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
  claimFileSystems = lib.mapAttrs' (
    _: claim:
    lib.nameValuePair claim.mountPoint (
      if claim.local then
        {
          device = claim.resolvedResource.sourcePath;
          fsType = "none";
          options = [
            "bind"
            "nofail"
            "x-systemd.requires-mounts-for=${claim.resolvedResource.backingMount}"
          ];
        }
      else
        {
          device = "${fleetNetwork.addressFor claim.provider}:${claim.resolvedResource.sourcePath}";
          fsType = "nfs";
          options = mountOptions;
        }
    )
  ) model.localClaims;
  defaultExportOptions = [
    "rw"
    "async"
    "no_subtree_check"
  ];
  exportOptions =
    resource:
    defaultExportOptions
    ++ [ "fsid=${toString resource.nfs.fsid}" ]
    ++ lib.optionals (resource.nfs.anonymousIdentity != null) (
      let
        user = config.users.users.${resource.nfs.anonymousIdentity};
        group = config.users.groups.${user.group};
      in
      [
        "anonuid=${toString user.uid}"
        "anongid=${toString group.gid}"
      ]
    );
  renderedExports = lib.concatMapStringsSep "\n" (
    claim:
    "${claim.resolvedResource.sourcePath} ${fleetNetwork.addressFor claim.clientName}(${lib.concatStringsSep "," (exportOptions claim.resolvedResource)})"
  ) model.providedRemoteClaims;
  directoryRules = map (
    directory:
    "${
      if directory.enforce then "z" else "d"
    } ${directory.absolutePath} ${directory.mode} ${directory.owner} ${directory.group} - -"
  ) model.uniqueDirectories;
  providedBackingMounts = lib.unique (
    map (claim: claim.resolvedResource.backingMount) model.providedRemoteClaims
  );
  providedPaths = lib.unique (
    map (claim: claim.resolvedResource.sourcePath) model.providedRemoteClaims
  );
in
{
  config = lib.mkMerge [
    {
      # All current NFS use is v4-only. NixOS enables rpcbind automatically
      # for NFS filesystems, but it is only needed by legacy NFSv3 helpers.
      services.rpcbind.enable = lib.mkOverride 75 false;

      host.autoUpgrade.claims.storage.exclusions = lib.mapAttrs (_: claim: {
        hosts = [ claim.provider ];
        minimumGapMinutes = 5;
      }) remoteClaims;

      host.network.stableAddress.requiredBy =
        lib.optional (model.providedRemoteClaims != [ ]) "NFS provider"
        ++ lib.optional (remoteClaims != { }) "NFS export ACL";
      users = {
        groups = model.managedGroups;
        users = model.managedUsers;
      };
      systemd.tmpfiles.rules = directoryRules;
    }

    (lib.mkIf (model.localClaims != { }) {
      fileSystems = claimFileSystems;
      virtualisation.vmVariant.virtualisation.fileSystems = claimFileSystems;
    })

    (lib.mkIf (remoteClaims != { }) {
      boot.supportedFilesystems = [ "nfs" ];
    })

    (lib.mkIf (model.providedRemoteClaims != [ ]) {
      services.nfs = {
        server = {
          enable = true;
          exports = renderedExports;
        };
        settings.nfsd = {
          port = 2049;
          vers3 = "n";
          vers4 = "y";
        };
      };

      systemd.services.nfs-server = {
        wantedBy = map (mount: "${utils.escapeSystemdPath mount}.mount") providedBackingMounts;
        unitConfig.RequiresMountsFor = providedBackingMounts ++ providedPaths;
      };

      networking.firewall.allowedTCPPorts = [ 2049 ];
    })
  ];
}
