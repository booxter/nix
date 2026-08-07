{
  config,
  hostInventory,
  lib,
  utils,
  ...
}:
let
  nfsPort = hostInventory.site.ports.nfs;
  dataVolume = config.host.storage.volumes.data;
  nfsExports = hostInventory.storage.nfs.exports;
  mediaExport = nfsExports.media;
  nixCacheExport = nfsExports.nixCache;
  paperlessExport = nfsExports.paperless;
  dataMountUnit = "${utils.escapeSystemdPath dataVolume.mountPoint}.mount";
  srvarrNfsAddress = hostInventory.toNixosHostIpv4Address "srvarr";
  cacheNfsAddress = hostInventory.toNixosHostIpv4Address "cache";
  orgNfsAddress = hostInventory.toNixosHostIpv4Address "org";
  paperlessExportPath = paperlessExport.path;
  paperlessUid = config.ids.uids.paperless;
  paperlessGid = config.ids.gids.paperless;

  # Pin export IDs so clients see stable export identities across server restarts.
  mkNfsExport =
    {
      path,
      client,
      fsid,
      extraOptions ? [ ],
    }:
    let
      options = [
        "rw"
        "async"
        "no_subtree_check"
        "fsid=${toString fsid}"
      ]
      ++ extraOptions;
    in
    "${path} ${client}(${lib.concatStringsSep "," options})";
in
{
  # NFS exports matching existing clients.
  services.nfs.server = {
    enable = true;
    exports = ''
      ${mkNfsExport {
        path = mediaExport.path;
        client = srvarrNfsAddress;
        fsid = mediaExport.fsid;
      }}
      ${mkNfsExport {
        path = nixCacheExport.path;
        client = cacheNfsAddress;
        fsid = nixCacheExport.fsid;
      }}
      ${mkNfsExport {
        path = paperlessExportPath;
        client = orgNfsAddress;
        fsid = paperlessExport.fsid;
        # Preserve root_squash while allowing root-run backup jobs on org to
        # read the Paperless-owned export as the Paperless service identity.
        extraOptions = [
          "anonuid=${toString paperlessUid}"
          "anongid=${toString paperlessGid}"
        ];
      }}
    '';
  };

  users.groups.paperless.gid = paperlessGid;
  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    uid = paperlessUid;
    home = paperlessExportPath;
    createHome = false;
  };

  systemd.tmpfiles.rules = [
    "d '${paperlessExportPath}' 0750 paperless paperless - -"
    "d '${paperlessExportPath}/consume' 0750 paperless paperless - -"
    "d '${paperlessExportPath}/export' 0750 paperless paperless - -"
    "d '${paperlessExportPath}/media' 0750 paperless paperless - -"
  ];

  systemd.services.nfs-server = {
    # If the data volume misses the initial boot transaction but mounts later, pull
    # NFS back up with it instead of leaving clients stuck until manual repair.
    wantedBy = [ dataMountUnit ];
    unitConfig.RequiresMountsFor = [
      dataVolume.mountPoint
      mediaExport.path
      nixCacheExport.path
      paperlessExportPath
    ];
  };

  services.nfs.settings.nfsd = {
    vers3 = "n";
    vers4 = "y";
  };

  services.rpcbind.enable = lib.mkForce false;

  networking.firewall.allowedTCPPorts = [ nfsPort ];
}
