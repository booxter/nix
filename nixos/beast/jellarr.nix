{ lib, inputs, ... }:
{
  imports = [
    inputs.jellarr.nixosModules.default
  ];

  services.jellarr = {
    enable = true;
    user = "jellyfin";
    group = "jellyfin";
    environmentFile = "/data/jellyfin.env"; # TODO: switch to sops
    config = {
      version = 1;
      base_url = "https://jf.ihar.dev:443";
      #base_url = "http://localhost:8096";
      system = {
        serverName = "main";
        enableMetrics = true;
        pluginRepositories = [
          {
            name = "Jellyfin Stable";
            url = "https://repo.jellyfin.org/files/plugin/manifest.json";
            enabled = true;
          }
          {
            name = "ThePornDB";
            url = "https://raw.githubusercontent.com/ThePornDatabase/Jellyfin.Plugin.ThePornDB/main/manifest.json";
            enabled = true;
          }
          {
            name = "Letterboxd Link";
            url = "https://raw.githubusercontent.com/zamhedonia/JellyfinLetterboxdLink/master/manifest.json";
            enabled = true;
          }
        ];
        trickplayOptions = {
          enableHwAcceleration = false;
          enableHwEncoding = false;
          processThreads = 10;
        };
      };
      encoding = {
        # TODO: revisit subtitle hardcoding policy once jellarr module exposes
        # explicit subtitle-mode/burn-in options declaratively.
        enableHardwareEncoding = true;
        hardwareAccelerationType = "vaapi";
        vaapiDevice = "/dev/dri/renderD128";
        hardwareDecodingCodecs = [
          "h264"
          "hevc"
          "vp9"
          "av1"
        ];
        enableDecodingColorDepth10Hevc = true;
        enableDecodingColorDepth10Vp9 = true;
        allowHevcEncoding = false;
        allowAv1Encoding = false;
      };
      library = {
        virtualFolders =
          let
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
                preferTmdb ? false,
              }:
              {
                pathInfos = [
                  { path = "/media/library/" + path; }
                ];

                typeOptions = getTypeOptions {
                  inherit isAdult preferTmdb;
                };

                automaticallyAddToCollection = true;

                enableChapterImageExtraction = true;
                extractChapterImagesDuringLibraryScan = true;
                extractTrickplayImagesDuringLibraryScan = true;
                enableEmbeddedEpisodeInfos = true;
                enableEmbeddedExtraTitles = true;
                enableTrickplayImageExtraction = true;

                saveTrickplayWithMedia = true;
                metadataSavers = [ "Nfo" ];
                saveLocalMetadata = true;

                automaticRefreshIntervalDays = 14;
                enableRealtimeMonitor = true;
              };
          in
          [
            # Movies and Shows
            {
              name = "Movies";
              collectionType = "movies";
              libraryOptions = getLibraryOptions { path = "movies"; };
            }
            {
              name = "Shows";
              collectionType = "tvshows";
              libraryOptions = getLibraryOptions { path = "shows"; };
            }
            {
              name = "Family";
              collectionType = "movies";
              libraryOptions = getLibraryOptions { path = "family"; };
            }
            {
              name = "Anime";
              collectionType = "movies";
              libraryOptions = getLibraryOptions { path = "anime"; };
            }
            {
              name = "Docu";
              collectionType = "movies";
              libraryOptions = getLibraryOptions { path = "docu"; };
            }

            # XXX
            {
              name = "Attic";
              collectionType = "movies";
              libraryOptions = getLibraryOptions {
                path = "attic";
                isAdult = true;
                preferTmdb = true;
              };
            }
            {
              name = "Fruit";
              collectionType = "movies";
              libraryOptions = getLibraryOptions {
                path = "xxx";
                isAdult = true;
                preferTmdb = true;
              };
            }

            # Other
            {
              name = "Music";
              collectionType = "music";
              libraryOptions = getLibraryOptions { path = "music"; };
            }
          ];
      };
      users =
        let
          getUser =
            {
              name,
              # It's ok-ish to keep it in plaintext here for now, since atm
              # jellarr uses the password only on initial creation. Of course,
              # after users are created, I have to update the passwords in UI
              # manually to avoid exposure.
              #
              # May need to change the strategy if/when jellarr updates
              # passwords for existing users:
              # https://github.com/venkyr77/jellarr/issues/51
              password ? "super-secret-" + name, # TODO: switch to sops
              isAdmin ? false,
              allowWrite ? false,
              isKid ? false,
              isAdult ? false,
              isGuest ? false,
              allLibraries ? false,
            }:
            {
              inherit name password;
              policy = {
                isAdministrator = isAdmin;
                enableAllFolders = allLibraries;
                enableCollectionManagement = allowWrite || isAdmin;
                loginAttemptsBeforeLockout = 3;
              }
              // lib.optionalAttrs isGuest {
                maxActiveSessions = 2;
              }
              // lib.optionalAttrs (!allLibraries) {
                enabledLibraries = [
                  "Family"
                ]
                ++ lib.optionals (!isKid) [
                  "Movies"
                  "Shows"
                  "Anime"
                  "Docu"
                  "Music"
                ]
                ++ lib.optionals isAdult [
                  "Attic"
                  "Fruit"
                ];
              };
              displayMissingEpisodes = true;
            };
          getGuestUser =
            args:
            getUser (
              args
              // {
                isAdmin = false;
                isKid = false;
                isAdult = false;
                isGuest = true;
                allLibraries = false;
              }
            );
        in
        [
          (getUser {
            name = "Ihar";
            isAdmin = true;
            isAdult = true;
            allowWrite = true;
          })
          (getUser {
            name = "jellyfin";
            isAdmin = false;
            isAdult = false;
          })
          (getUser {
            name = "Kasia";
            isAdult = true;
            allowWrite = true;
          })
          (getUser {
            name = "Vatslau";
            isKid = true;
          })
          (getUser {
            name = "Guest";
            isAdmin = false;
            isAdult = false;
            allowWrite = false;
          })

          (getGuestUser { name = "DZ"; })
          (getGuestUser { name = "ZS"; })
          (getGuestUser { name = "Olga"; })
        ];
      plugins = map (name: { inherit name; }) [
        "AudioDB"
        "Letterboxd Link on Movies"
        "MusicBrainz"
        "OMDb"
        "Studio Images"
        "ThePornDB"
        "TheTVDB"
        "TMDb"
      ];
    };
  };
}
