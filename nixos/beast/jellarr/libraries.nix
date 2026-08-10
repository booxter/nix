{
  config,
  facts,
  lib,
  ...
}:
let
  getTypeOptions = import ./library-types.nix { inherit lib; };
  libraryRoot = "${config.host.jellyfin.media.mountPoint}/library";
  getLibraryOptions =
    {
      path,
      isAdult ? false,
      isMusic ? false,
      preferTmdb ? false,
    }:
    {
      pathInfos = [ { path = "${libraryRoot}/${path}"; } ];
      typeOptions = getTypeOptions { inherit isAdult preferTmdb; };
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
    // lib.optionalAttrs isMusic {
      saveLyricsWithMedia = true;
      useCustomTagDelimiters = true;
      customTagDelimiters = [ ";" ];
      delimiterWhitelist = [ ];
    };
in
{
  host.jellyfin.declarativeConfig.library.virtualFolders = map (library: {
    inherit (library) name collectionType;
    libraryOptions = getLibraryOptions {
      inherit (library) path;
      isAdult = library.isAdult or false;
      isMusic = library.collectionType == "music";
      preferTmdb = library.preferTmdb or false;
    };
  }) facts.media-libraries.libraries;
}
