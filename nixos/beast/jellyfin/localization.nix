{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  root = "${config.host.jellyfin.media.mountPoint}/localized/ru";
  tools = pkgs.callPackage ../../_mixins/jellyfin/packages/tools { };
  settings = pkgs.writeText "polyglot.json" (
    builtins.toJSON {
      Name = "Русский";
      LanguageCode = "ru-RU";
      MetadataLanguage = "ru";
      MetadataCountry = "RU";
      DestinationBasePath = root;
      MirroredLibraries = map (library: {
        SourceLibraryName = library.sourceName;
        TargetLibraryName = library.name;
        TargetPath = "${root}/${library.path}";
      }) model.localizedLibraries;
    }
  );
in
{
  # Ordinary directories on the media filesystem: hardlinks cannot cross a
  # Btrfs subvolume boundary. Keep mirrors outside every original library.
  host.storage.claims.jellyfin-media.directories = builtins.listToAttrs (
    map (path: lib.nameValuePair path { }) (
      [
        "localized"
        "localized/ru"
      ]
      ++ map (library: "localized/ru/${library.path}") model.localizedLibraries
    )
  );

  # Populate only after Jellarr has installed the plugin, created the empty
  # libraries, and restricted every account to its explicit library list.
  # The first installation needs a Jellyfin restart to load the plugin.
  systemd.services.jellarr.serviceConfig.ExecStartPost = [
    "${tools}/bin/jellyfin-polyglot --url http://127.0.0.1:8096 --config ${settings}"
  ];
}
