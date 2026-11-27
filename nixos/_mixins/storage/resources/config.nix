{
  config,
  lib,
  storageModel,
  utils,
  ...
}:
let
  model = storageModel;
  siteNetwork = import ../../../../common/_lib/site-network.nix { inherit config; };
  remoteClaims = lib.filterAttrs (_: claim: !claim.local) model.localClaims;
  nestedClaim =
    claim:
    lib.any (parent: lib.hasPrefix "${parent.mountPoint}/" claim.mountPoint) (
      builtins.attrValues remoteClaims
    );
  mountOptions = [
    "nfsvers=4"
    "hard"
    "nofail"
    "_netdev"
    "noatime"
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
          device = "${siteNetwork.addressFor claim.provider}:${claim.resolvedResource.sourcePath}";
          fsType = "nfs";
          # NFS already discovers nested exports while resolving the mountpoint.
          # An autofs mount above that discovered mount hides it and loops with
          # ELOOP. Use an ordinary mount for claims below another remote claim.
          options =
            mountOptions
            ++ lib.optionals (!(nestedClaim claim)) [
              "x-systemd.automount"
              "x-systemd.idle-timeout=0"
            ];
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
    "${claim.resolvedResource.sourcePath} ${siteNetwork.addressFor claim.clientName}(${lib.concatStringsSep "," (exportOptions claim.resolvedResource)})"
  ) model.providedRemoteClaims;
  directoryRules = map (
    directory: "d ${directory.absolutePath} ${directory.mode} ${directory.owner} ${directory.group} - -"
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

      host.autoUpgrade.claims.storage.exclusions = map (claim: {
        hosts = [ claim.provider ];
        minimumGapMinutes = 5;
      }) (builtins.attrValues remoteClaims);

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
      # Looking up a nested export can create an expirable NFS mount before
      # systemd runs mount.nfs. Keep it mounted so idle expiry cannot remove
      # writable paths from running services' mount namespaces.
      boot.kernelModules = [ "nfs" ];
      boot.kernel.sysctl."fs.nfs.nfs_mountpoint_timeout" = 0;
      # Keep routes to hard-mounted NFS shares available across DHCP restarts.
      networking.dhcpcd.extraConfig = "persistent";
    })

    {
      systemd.services = lib.mkMerge (
        map (attachment: {
          ${attachment.unit}.unitConfig.RequiresMountsFor = [ attachment.mountPoint ];
        }) model.localAttachments
      );
    }

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
