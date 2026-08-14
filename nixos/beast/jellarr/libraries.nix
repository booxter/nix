{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  libraryRoot = "${config.host.jellyfin.media.mountPoint}/library";
  getLibraryOptions =
    {
      path,
      kind,
      typeOptions,
    }:
    {
      pathInfos = [ { path = "${libraryRoot}/${path}"; } ];
      inherit typeOptions;
      automaticallyAddToCollection = true;
      enableChapterImageExtraction = true;
      # Generate these on demand or via dedicated jobs, not during scans.
      extractChapterImagesDuringLibraryScan = false;
      extractTrickplayImagesDuringLibraryScan = false;
      enableEmbeddedEpisodeInfos = true;
      enableEmbeddedExtraTitles = true;
      enableTrickplayImageExtraction = true;
      saveTrickplayWithMedia = true;
      metadataSavers = [ "Nfo" ];
      saveLocalMetadata = true;
      automaticRefreshIntervalDays = 14;
      enableRealtimeMonitor = true;
    }
    // lib.optionalAttrs (kind == "music") {
      saveLyricsWithMedia = true;
      useCustomTagDelimiters = true;
      customTagDelimiters = [ ";" ];
      delimiterWhitelist = [ ];
    };
in
{
  host.jellyfinDeclarativeConfig.library.virtualFolders = map (library: {
    inherit (library) name collectionType;
    libraryOptions = getLibraryOptions {
      inherit (library) path kind typeOptions;
    };
  }) model.libraries;
}
