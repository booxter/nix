{
  config,
  hostInventory,
  hostSpec,
  lib,
  utils,
  ...
}:
let
  hostName = hostSpec.name;
  nfsPort = 2049;
  provider = hostInventory.nfs.providers.${hostName} or null;
  hostLinks = hostInventory.nfs.links.${hostName} or { };
  allLinks = lib.concatMapAttrs (
    clientName:
    lib.mapAttrs' (
      linkName: link:
      lib.nameValuePair "${clientName}-${linkName}" (
        link
        // {
          inherit clientName linkName;
        }
      )
    )
  ) hostInventory.nfs.links;
  providedLinks = lib.filterAttrs (_: link: link.provider == hostName) allLinks;
  providedExports = if provider == null then { } else provider.exports;
  participatingExports =
    providedExports
    // builtins.listToAttrs (
      map (link: {
        name = "${link.provider}-${link.exportName}";
        value = hostInventory.nfs.providers.${link.provider}.exports.${link.exportName};
      }) (builtins.attrValues hostLinks)
    );
  sharedGroups =
    lib.mapAttrs'
      (
        _: export:
        lib.nameValuePair export.permissions.sharedGroup.name {
          inherit (export.permissions.sharedGroup) gid;
        }
      )
      (
        lib.filterAttrs (
          _: export: export ? permissions && export.permissions ? sharedGroup
        ) participatingExports
      );
  anonymousIdentityNames = lib.unique (
    map (export: export.anonymousIdentity) (
      builtins.attrValues (lib.filterAttrs (_: export: export ? anonymousIdentity) participatingExports)
    )
  );
  anonymousIdentityAssertions = lib.concatMap (
    name:
    let
      expected = hostInventory.accounts.users.${name};
      user = config.users.users.${name} or null;
      group = config.users.groups.${expected.group} or null;
    in
    [
      {
        assertion = user != null && user.uid == expected.uid;
        message = "NFS anonymous identity ${name} must use UID ${toString expected.uid}";
      }
      {
        assertion = group != null && group.gid == hostInventory.accounts.groups.${expected.group}.gid;
        message = "NFS anonymous identity ${name} must use the shared ${expected.group} GID";
      }
    ]
  ) anonymousIdentityNames;
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
  clientFileSystems = lib.mapAttrs' (
    _: link:
    lib.nameValuePair link.mountPoint {
      device = "${hostInventory.toNixosHostIpv4Address link.provider}:${link.exportPath}";
      fsType = "nfs";
      options = mountOptions;
    }
  ) hostLinks;
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
  renderedExports = lib.concatMapStringsSep "\n" (
    exportName:
    let
      export = provider.exports.${exportName};
      clients = lib.filterAttrs (_: link: link.exportName == exportName) providedLinks;
    in
    lib.concatMapStringsSep "\n" (
      link:
      "${export.path} ${hostInventory.toNixosHostIpv4Address link.clientName}(${lib.concatStringsSep "," (exportOptions export)})"
    ) (builtins.attrValues clients)
  ) (builtins.attrNames providedExports);
  exportPaths = map (export: export.path) (builtins.attrValues providedExports);
in
{
  config = lib.mkMerge [
    {
      assertions = anonymousIdentityAssertions;
      users.groups = sharedGroups;
    }

    (lib.mkIf (hostLinks != { }) {
      boot.supportedFilesystems = [ "nfs" ];
      fileSystems = clientFileSystems;
      virtualisation.vmVariant.virtualisation.fileSystems = clientFileSystems;
    })

    (lib.mkIf (provider != null) {
      assertions = [
        {
          assertion = lib.all (
            exportName: builtins.any (link: link.exportName == exportName) (builtins.attrValues providedLinks)
          ) (builtins.attrNames providedExports);
          message = "NFS provider ${hostName} has an export without a client link";
        }
      ];

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
        wantedBy = [ "${utils.escapeSystemdPath provider.backingMount}.mount" ];
        unitConfig.RequiresMountsFor = [ provider.backingMount ] ++ exportPaths;
      };

      networking.firewall.allowedTCPPorts = [ nfsPort ];
    })
  ];
}
