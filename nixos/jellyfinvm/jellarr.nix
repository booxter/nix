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
        ];
        trickplayOptions = {
          enableHwAcceleration = false;
          enableHwEncoding = false;
          processThreads = 10;
        };
      };
      encoding = {
        allowHevcEncoding = true;
        allowAv1Encoding = true;
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
                    "TheMovieDb"
                    "The Open Movie Database"
                  ];
                  imageFetchers = [
                    "TheMovieDb"
                  ];
                }
                {
                  type = "Season";
                  metadataFetchers = [
                    "TheMovieDb"
                  ];
                  imageFetchers = [
                    "TheMovieDb"
                  ];
                }
                {
                  type = "Episode";
                  metadataFetchers = [
                    "TheMovieDb"
                    "The Open Movie Database"
                  ];
                  imageFetchers = [
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
              name = "Fruit";
              collectionType = "movies";
              libraryOptions = getLibraryOptions {
                path = "xxx";
                isAdult = true;
                preferTmdb = true;
              };
            }
            {
              name = "Shout";
              collectionType = "movies";
              libraryOptions = getLibraryOptions {
                path = "whisparr/scenes";
                isAdult = true;
              };
            }
            {
              name = "Whisper";
              collectionType = "movies";
              libraryOptions = getLibraryOptions {
                path = "whisparr/movies";
                isAdult = true;
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
              allLibraries ? false,
            }:
            {
              inherit name password;
              policy = {
                isAdministrator = isAdmin;
                enableAllFolders = allLibraries;
                enableCollectionManagement = allowWrite || isAdmin;
                loginAttemptsBeforeLockout = 3;
              };
              displayMissingEpisodes = true;
              subtitleLanguagePreference = "en";
            }
            // lib.optionalAttrs (!allLibraries) {
              policy.enabledLibraries = [
                "Family"
              ]
              ++ lib.optionals (!isKid) [
                "Movies"
                "Shows"
                "Anime"
                "Docu"
                "Music"
              ]
              ++ lib.optionals isAdult [ "Fruit" ];
            };
          getGuestUser =
            args:
            (getUser (
              args
              // {
                isAdmin = false;
                isKid = false;
                isAdult = false;
                allLibraries = false;
              }
            ))
            // {
              maxActiveSessions = 2;
            };
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

          (getGuestUser { name = "DZ"; })
          (getGuestUser { name = "ZS"; })
        ];
      plugins = builtins.map (name: { inherit name; }) [
        "AudioDB"
        "MusicBrainz"
        "OMDb"
        "Studio Images"
        "ThePornDB"
        "TMDb"
      ];
    };
  };
}
