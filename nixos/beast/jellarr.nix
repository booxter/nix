{
  config,
  lib,
  inputs,
  ...
}:
let
  mkJellyfinUserPasswordSecret = name: "jellyfin/users/${lib.toLower name}/password";
  jellyfinSecretFile = {
    owner = "jellyfin";
    group = "jellyfin";
    mode = "0400";
  };
  userDefinitions = [
    {
      name = "Ihar";
      isAdmin = true;
      isAdult = true;
      allowWrite = true;
    }
    {
      name = "jellyfin";
      isAdmin = false;
      isAdult = false;
    }
    {
      name = "Kasia";
      isAdult = true;
      allowWrite = true;
    }
    {
      name = "Vatslau";
      isKid = true;
    }
    {
      name = "Guest";
      isAdmin = false;
      isAdult = false;
      allowWrite = false;
    }
    {
      name = "DZ";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
      allLibraries = false;
    }
    {
      name = "ZD";
      isAdmin = false;
      isKid = false;
      isAdult = true;
      isGuest = true;
      allLibraries = true;
    }
    {
      name = "ZS";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
      allLibraries = false;
      extraLibraries = [ "Attic" ];
    }
    {
      name = "Olga";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
      allLibraries = false;
    }
  ];
in
{
  imports = [
    inputs.jellarr.nixosModules.default
  ];

  sops = {
    secrets = builtins.listToAttrs (
      map (user: {
        name = mkJellyfinUserPasswordSecret user.name;
        value = jellyfinSecretFile;
      }) userDefinitions
    );
    templates."jellarr.env" = {
      inherit (jellyfinSecretFile) owner group mode;
      content = ''
        JELLARR_API_KEY=${config.sops.placeholder."jellyfin/apiKey"}
      '';
    };
  };

  systemd.services.jellarr = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  services.jellarr = {
    enable = true;
    user = "jellyfin";
    group = "jellyfin";
    environmentFile = config.sops.templates."jellarr.env".path;
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
          enableHwAcceleration = true;
          enableHwEncoding = true;
          processThreads = 10;
        };
      };
      network = {
        knownProxies = [ "127.0.0.1" ];
      };
      encoding = {
        # TODO: revisit subtitle hardcoding policy once jellarr module exposes
        # explicit subtitle-mode/burn-in options declaratively.
        enableHardwareEncoding = true;
        hardwareAccelerationType = "qsv";
        qsvDevice = "/dev/dri/renderD128";
        hardwareDecodingCodecs = [
          "h264"
          "hevc"
          "vp9"
          "av1"
        ];
        enableDecodingColorDepth10Hevc = true;
        enableDecodingColorDepth10Vp9 = true;
        allowHevcEncoding = true;
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
              isAdmin ? false,
              allowWrite ? false,
              isKid ? false,
              isAdult ? false,
              isGuest ? false,
              allLibraries ? false,
              extraLibraries ? [ ],
            }:
            {
              inherit name;
              passwordFile = config.sops.secrets.${mkJellyfinUserPasswordSecret name}.path;
              policy = {
                isAdministrator = isAdmin;
                enableAllFolders = allLibraries;
                enableCollectionManagement = allowWrite || isAdmin;
                loginAttemptsBeforeLockout = 3;
                # 10 Mbps (Jellyfin policy expects bits/sec).
                # Spectrum upload is maxed at 35 Mbps, so this should
                # accommodate a few maxed out streams plus backups etc.
                remoteClientBitrateLimit = 10 * 1000 * 1000;
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
                ]
                ++ extraLibraries;
              };
              displayMissingEpisodes = true;
              subtitleLanguagePreference = "eng";
            };
        in
        map getUser userDefinitions;
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
