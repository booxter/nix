{
  hostInventory,
  lib,
  ...
}:
let
  mediaLibraries = import ./jellyfin/media-libraries.nix;
  servarrAccounts = import ../srvarr/accounts.nix;
  mediaExport = hostInventory.storage.nfs.exports.media;
  projectPaths = builtins.mapAttrs (
    _: value: if builtins.isAttrs value then projectPaths value else "${mediaExport.path}/${value}"
  );
  mediaPaths = projectPaths mediaExport.layout;
  pinepodsUser = toString servarrAccounts.uids.pinepods;
  rommUser = toString servarrAccounts.uids.romm;
  slskdUser = toString servarrAccounts.uids.slskd;

  mkTmpfilesDir = path: mode: user: group: [
    "d ${path} ${mode} ${user} ${group} - -"
    "z ${path} ${mode} ${user} ${group} - -"
  ];
  mkDirSpec = mode: user: path: {
    inherit mode path user;
    group = "media";
  };
  mkDirSpecs = mode: user: map (mkDirSpec mode user);

  mediaDirSpecs =
    mkDirSpecs "2775" "root" [
      mediaPaths.library.root
      mediaPaths.library.books
      mediaPaths.library.audiobooks
      mediaPaths.library.flows
    ]
    # The media tree is exported to srvarr. Use srvarr's numeric service IDs
    # so ownership is meaningful on the NFS client.
    ++ mkDirSpecs "2775" "root" [ mediaPaths.pinepods.root ]
    ++ mkDirSpecs "2775" pinepodsUser [ mediaPaths.pinepods.downloads ]
    ++ mkDirSpecs "2775" rommUser [
      mediaPaths.romm.root
      mediaPaths.romm.assets
      mediaPaths.romm.cache
      mediaPaths.romm.config
      mediaPaths.romm.resources
      mediaPaths.romm.sync
      mediaPaths.romm.library
      mediaPaths.romm.roms
      mediaPaths.romm.pcRoms
      mediaPaths.romm.bios
    ]
    ++ mkDirSpecs "0755" "70" (
      [
        mediaPaths.transmission.root
        mediaPaths.transmission.incomplete
        mediaPaths.transmission.watch
      ]
      ++ builtins.attrValues mediaPaths.transmission.categories
    )
    ++ mkDirSpecs "2775" slskdUser [
      mediaPaths.slskd.root
      mediaPaths.slskd.incomplete
      mediaPaths.slskd.complete
    ]
    ++ mkDirSpecs "0755" "38" [
      mediaPaths.sabnzbd.root
      mediaPaths.sabnzbd.incomplete
      mediaPaths.sabnzbd.watch
    ]
    ++ mkDirSpecs "0775" "38" (
      [ mediaPaths.sabnzbd.complete ] ++ builtins.attrValues mediaPaths.sabnzbd.categories
    )
    ++ map (library: {
      path = "${mediaPaths.library.root}/${library.path}";
      mode = "2775";
      user = "root";
      group = "media";
    }) mediaLibraries;
in
{
  systemd.tmpfiles.rules = lib.concatMap (
    spec: mkTmpfilesDir spec.path spec.mode spec.user spec.group
  ) mediaDirSpecs;
}
