{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  media = {
    device = "nas-lab:/volume2/Media";
    fsType = "nfs";
  };
in
{
  imports = [
    inputs.declarative-jellyfin.nixosModules.default
  ];

  services.declarative-jellyfin = let
    getSvcDir = name: "/media/.jf/" + name;
    in {
    enable = true;
    openFirewall = true;
    serverId = "4d6980bd291d37fa006ece1e8e7fe752";

    backups = true;
    backupCount = 5;

    #dataDir = getSvcDir "data";
    #backupDir = getSvcDir "backups";
    #cacheDir = getSvcDir "cache";

    system = {
      enableMetrics = true;
      #metadataPath = getSvcDir "metadata";
      pluginRepositories = [
        {
          content = {
           Enabled = true;
           Name = "Jellyfin Stable";
           Url = "https://repo.jellyfin.org/files/plugin/manifest.json";
          };
          tag = "RepositoryInfo";
        }
        {
          content = {
           Enabled = true;
           Name = "ThePornDB";
           Url = "https://raw.githubusercontent.com/ThePornDatabase/Jellyfin.Plugin.ThePornDB/main/manifest.json";
          };
          tag = "RepositoryInfo";
        }
      ];
      serverName = "main";
    };

    encoding = {
      allowAv1Encoding = true;
      allowHevcEncoding = true;
    };

    libraries = let
      # TODO: refactor to use common fetcher config templates
      getTypeOptions = isAdult: if isAdult then {
        typeOptions.Movies = {
          metadataFetchers = [
            "ThePornDB Movies"
            "ThePornDB Scenes"
            "ThePornDB JAV"
            "TheMovieDb"
            "The Open Movie Database"
          ];
          imageFetchers = [
            "ThePornDB Movies"
            "ThePornDB Scenes"
            "ThePornDB JAV"
            "TheMovieDb"
            "The Open Movie Database"
          ];
        };
        typeOptions.Shows = {
          metadataFetchers = [
            "ThePornDB Scenes"
            "ThePornDB Movies"
            "ThePornDB JAV"
            "TheMovieDb"
            "The Open Movie Database"
          ];
          imageFetchers = [
            "ThePornDB Scenes"
            "ThePornDB Movies"
            "ThePornDB JAV"
            "TheMovieDb"
            "The Open Movie Database"
          ];
        };
      } else {
        typeOptions.Movies = {
          metadataFetchers = [
            "TheMovieDb"
            "The Open Movie Database"
          ];
          imageFetchers = [
            "TheMovieDb"
            "The Open Movie Database"
          ];
        };
        typeOptions.Shows = {
          metadataFetchers = [
            "TheMovieDb"
            "The Open Movie Database"
          ];
          imageFetchers = [
            "TheMovieDb"
            "The Open Movie Database"
          ];
        };
        typeOptions.Music = {
          metadataFetchers = [
            "TheAudioDB"
            "MusicBrainz"
          ];
          imageFetchers = [
            "TheAudioDB"
            "MusicBrainz"
          ];
        };
      };

      getLibrary = { path, contentType ? "movies", isAdult ? false }: {
        enabled = true;
        inherit contentType;
        pathInfos = [ path ];

        automaticallyAddToCollection = true;

        enableChapterImageExtraction = true;
        extractChapterImagesDuringLibraryScan = true;
        extractTrickplayImagesDuringLibraryScan = true;
        enableEmbeddedEpisodeInfos = true;
        enableEmbeddedExtraTitles = true;
        enableTrickplayImageExtraction = true;

        saveTrickplayWithMedia = true;
        saveLocalMetadata = true;

        automaticRefreshIntervalDays = 14;
        enableRealtimeMonitor = true;
      } // getTypeOptions isAdult;

      getMediaPath = name: "/media/library/" + name;
    in {
      Movies = getLibrary { path = getMediaPath "movies"; };
      Anime = getLibrary { path = getMediaPath "anime"; };
      Docu = getLibrary { path = getMediaPath "docu"; };

      Shows = getLibrary { path = getMediaPath "shows"; contentType = "tvshows"; };
      Music = getLibrary { path = getMediaPath "music"; contentType = "music"; };

      Fruit = getLibrary { path = getMediaPath "xxx"; isAdult = true; };
      Whisper = getLibrary { path = getMediaPath "whisparr/movies"; isAdult = true; };
      Shout = getLibrary { path = getMediaPath "whisparr/scenes"; isAdult = true; };
    };

    users =
      let
        hashedPassword = "$PBKDF2-SHA512$iterations=210000$535A9D75492726EB4D49339E800FC209$A870512E4964ECC260389C9864CEA085FD501945B7526D7F813560BFCA5A728E8E7522BA597C646D339F0193E0CFF8107416DB5EE234E69B6D0AC441A77B4079";
        getUser = { mutable ? true, isAdmin ? false, allowWrite ? false, isKid ? false, isAdult ? false, allLibraries ? false }: {
          inherit mutable hashedPassword;
          permissions = {
            isAdministrator = isAdmin;
            enableAllFolders = allLibraries;
            enableCollectionManagement = allowWrite || isAdmin;
          };
          displayMissingEpisodes = true;
          subtitleLanguagePreference = "en";
        } // lib.optionalAttrs (!allLibraries) {
          preferences.enabledLibraries = [ "Movies" "Anime" "Docu" "Shows" "Music" ] ++ lib.optionals isAdult [ "Fruit" ];
        };
        getGuestUser = (getUser { mutable = true; isAdmin = false; isKid = false; isAdult = false; allLibraries = false; }) // { maxActiveSessions = 2; };
      in
      {
        Ihar = getUser { mutable = false; isAdmin = true; isAdult = true; };
        Kasia = getUser { mutable = false; isAdult = true; allowWrite = true; };
        Vatslau = getUser { mutable = false; isKid = true; };

        ZS = getGuestUser;
        DZ = getGuestUser;
      };
  };

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # Reverse proxy with automatic TLS
  security.acme = {
    acceptTerms = true;
    defaults.email = "ihar.hrachyshka@gmail.com";
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      "jf.ihar.dev" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          proxyWebsockets = true;
        };
      };
      "js.ihar.dev" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "http://prox-srvarrvm:5055";
          proxyWebsockets = true;
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."/media" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."/media" = media;

  # Acceleration setup: https://nixos.wiki/wiki/Jellyfin
  nixpkgs.config.packageOverrides = pkgs: {
    intel-vaapi-driver = pkgs.intel-vaapi-driver.override { enableHybridCodec = true; };
  };
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver # previously vaapiIntel
      libva-vdpau-driver
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      vpl-gpu-rt # QSV on 11th gen or newer
    ];
  };

  # ports for local vm access
  virtualisation.vmVariant.virtualisation.forwardPorts = [
    {
      from = "host";
      guest.port = 8096;
      host.port = 8096;
    }
    {
      from = "host";
      guest.port = 8920;
      host.port = 8920;
    }
    {
      from = "host";
      guest.port = 7359;
      host.port = 7359;
    }
  ];
}
