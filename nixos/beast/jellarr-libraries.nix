{
  hostInventory,
  lib,
  ...
}:
let
  mediaLibraries = import ./media-libraries.nix;
  mediaPaths = import ./media-paths.nix { inherit hostInventory; };
  getTypeOptions =
    {
      isAdult ? false,
      preferTmdb ? false,
    }:
    [
      (
        {
          type = "Movie";
          metadataFetchers =
            lib.optionals isAdult [
              "ThePornDB Movies"
              "ThePornDB Scenes"
              "ThePornDB JAV"
            ]
            ++ [
              "TheMovieDb"
              "The Open Movie Database"
            ];

          imageFetchers =
            lib.optionals isAdult [
              "ThePornDB"
            ]
            ++ [
              "TheMovieDb"
              "The Open Movie Database"
              "Embedded Image Extractor"
              "Screen Grabber"
            ];
        }
        // lib.optionalAttrs (isAdult && preferTmdb) {
          metadataFetcherOrder = [
            "TheMovieDb"
            "ThePornDB Movies"
            "ThePornDB Scenes"
            "ThePornDB JAV"
            "The Open Movie Database"
          ];
          imageFetcherOrder = [
            "TheMovieDb"
            "ThePornDB"
            "The Open Movie Database"
            "Embedded Image Extractor"
            "Screen Grabber"
          ];
        }
      )
      {
        type = "Series";
        metadataFetchers = [
          "Missing Episode Fetcher"
          "TheTVDB"
          "TheMovieDb"
          "The Open Movie Database"
        ];
        imageFetchers = [
          "TheTVDB"
          "TheMovieDb"
        ];
      }
      {
        type = "Season";
        metadataFetchers = [
          "TheTVDB"
          "TheMovieDb"
        ];
        imageFetchers = [
          "TheTVDB"
          "TheMovieDb"
        ];
      }
      {
        type = "Episode";
        metadataFetchers = [
          "TheTVDB"
          "TheMovieDb"
          "The Open Movie Database"
        ];
        imageFetchers = [
          "TheTVDB"
          "TheMovieDb"
          "The Open Movie Database"
          "Embedded Image Extractor"
          "Screen Grabber"
        ];
      }
      {
        type = "MusicArtist";
        metadataFetchers = [ "MusicBrainz" ];
        imageFetchers = [ "TheAudioDB" ];
      }
      {
        type = "MusicAlbum";
        metadataFetchers = [ "MusicBrainz" ];
        imageFetchers = [ "TheAudioDB" ];
      }
      {
        type = "Audio";
        metadataFetchers = [ ];
        imageFetchers = [ "Image Extractor" ];
      }
      {
        type = "MusicVideo";
        metadataFetchers = [ ];
        imageFetchers = [
          "Embedded Image Extractor"
          "Screen Grabber"
        ];
      }
    ];
  getLibraryOptions =
    {
      path,
      isAdult ? false,
      isMusic ? false,
      preferTmdb ? false,
    }:
    {
      pathInfos = [
        { path = mediaPaths.jellyfinLibraryRoot + "/" + path; }
      ];

      typeOptions = getTypeOptions {
        inherit isAdult preferTmdb;
      };

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
  services.jellarr.config.library.virtualFolders = map (library: {
    inherit (library) name collectionType;
    libraryOptions = getLibraryOptions {
      inherit (library) path;
      isAdult = library.isAdult or false;
      isMusic = library.collectionType == "music";
      preferTmdb = library.preferTmdb or false;
    };
  }) mediaLibraries;
}
