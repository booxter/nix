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

  services.declarative-jellyfin = {
    enable = true;
    openFirewall = true;
    serverId = "4d6980bd291d37fa006ece1e8e7fe752";

    libraries = {
      Movies = {
        enabled = true;
        contentType = "movies";
        pathInfos = [ "/media/library/movies" ];
        typeOptions.Movies = {
          metadataFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
          imageFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
        };
      };
      Shows = {
        enabled = true;
        contentType = "tvshows";
        pathInfos = [ "/media/library/shows" ];
        typeOptions.Shows = {
          metadataFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
          imageFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
        };
      };
      Fruit = {
        enabled = true;
        contentType = "movies";
        pathInfos = [ "/media/library/xxx" ];
        typeOptions.Movies = {
          metadataFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
          imageFetchers = [
            "The Open Movie Database"
            "TheMovieDb"
          ];
        };
      };
      Music = {
        enabled = true;
        contentType = "music";
        pathInfos = [ "/media/library/music" ];
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
    };

    users =
      let
        hashedPassword = "$PBKDF2-SHA512$iterations=210000$535A9D75492726EB4D49339E800FC209$A870512E4964ECC260389C9864CEA085FD501945B7526D7F813560BFCA5A728E8E7522BA597C646D339F0193E0CFF8107416DB5EE234E69B6D0AC441A77B4079";
      in
      {
        Ihar = {
          mutable = false;
          inherit hashedPassword;
          permissions = {
            isAdministrator = true;
          };
        };
        Kasia = {
          mutable = false;
          inherit hashedPassword;
          permissions = {
            isAdministrator = false;
          };
        };
        Vatslau = {
          mutable = false;
          inherit hashedPassword;
          permissions = {
            isAdministrator = false;
          };
        };
        ZS = {
          mutable = true;
          inherit hashedPassword;
          maxActiveSessions = 1;
          permissions = {
            isAdministrator = false;
          };
        };
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

  networking.firewall.allowedTCPPorts = [ 80 443 ];

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
