{
  config,
  hostInventory,
  inputs,
  ...
}:
let
  wgConservativeUploadRateMbit = 8;
  transmissionNonPreferredLowPriorityRatio = 3.0;
  transmissionNonPreferredPauseRatio = 6.0;
  jellyseerrService = hostInventory.servicesById.jellyseerr;
  aurralService = hostInventory.servicesById.aurral;
  audiobookshelfService = hostInventory.servicesById.audiobookshelf;
  shelfmarkService = hostInventory.servicesById.shelfmark;
in
{
  _module.args = {
    inherit
      transmissionNonPreferredLowPriorityRatio
      transmissionNonPreferredPauseRatio
      wgConservativeUploadRateMbit
      ;
  };

  imports = [
    inputs.vpnconfinement.nixosModules.default
    ./audiobookshelf.nix
    ./contract.nix
    ./aurral.nix
    ./backup.nix
    ./bazarr.nix
    ./glance.nix
    ./nfs.nix
    ./qos.nix
    ./sabnzbd.nix
    ./sabnzbd-exporter.nix
    ./seerr.nix
    ./shelfmark.nix
    ./transmission.nix
    ./transmission-torrent-cleaner.nix
    ./transmission-prioritizer.nix
    ./vpn.nix
    ./wg-bridge-access.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;

  systemd.services.prowlarr.unitConfig = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };

  services = {
    radarr = {
      enable = true;
      dataDir = config.host.srvarr.services.radarr.stateDir;
      user = config.host.srvarr.services.radarr.user;
      group = config.host.srvarr.services.radarr.group;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
    };
    sonarr = {
      enable = true;
      dataDir = config.host.srvarr.services.sonarr.stateDir;
      user = config.host.srvarr.services.sonarr.user;
      group = config.host.srvarr.services.sonarr.group;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
    };
    lidarr = {
      enable = true;
      dataDir = config.host.srvarr.services.lidarr.stateDir;
      user = config.host.srvarr.services.lidarr.user;
      group = config.host.srvarr.services.lidarr.group;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
    };
    prowlarr = {
      enable = true;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d '${config.host.srvarr.services.prowlarr.stateDir}' 0700 ${config.host.srvarr.services.prowlarr.user} root - -"
  ];

  systemd.services.prowlarr.serviceConfig = {
    # `User` and `Group` override `DynamicUser = true` from the NixOS Prowlarr
    # module because a matching static account exists.
    User = config.host.srvarr.services.prowlarr.user;
    Group = config.host.srvarr.services.prowlarr.group;
    ExecStart = inputs.nixpkgs.lib.mkForce "${config.services.prowlarr.package}/bin/Prowlarr -nobrowser -data=${config.host.srvarr.services.prowlarr.stateDir}";
    ReadWritePaths = [ config.host.srvarr.services.prowlarr.stateDir ];
  };

  users = {
    groups = {
      ${config.host.srvarr.services.prowlarr.group}.gid = 287;
      lidarr-api = { };
      prowlarr-api = { };
      radarr-api = { };
      sonarr-api = { };
    };
    users = {
      ${config.host.srvarr.services.prowlarr.user} = {
        isSystemUser = true;
        group = config.host.srvarr.services.prowlarr.group;
        home = "/var/empty";
        uid = 293;
        extraGroups = [ "prowlarr-api" ];
      };
      ${config.host.srvarr.services.radarr.user} = {
        isSystemUser = true;
        extraGroups = [ "radarr-api" ];
      };
      ${config.host.srvarr.services.sonarr.user} = {
        isSystemUser = true;
        extraGroups = [ "sonarr-api" ];
      };
      ${config.host.srvarr.services.lidarr.user}.isSystemUser = true;
    };
  };

  host.internalHttps.services = {
    radarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.radarr.settings.server.port}";
    };
    sonarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.sonarr.settings.server.port}";
    };
    lidarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}";
    };
    bazarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
    };
    prowlarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.prowlarr.settings.server.port}";
    };
    jellyseerr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
      serverAliases = [ jellyseerrService.publicHost ];
      mtls.enable = true;
    };
    aurral = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.aurral.port}";
      serverAliases = [ aurralService.publicHost ];
      mtls.enable = true;
    };
    audiobookshelf = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.audiobookshelf.port}";
      serverAliases = [ audiobookshelfService.publicHost ];
      mtls.enable = true;
    };
    shelfmark = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.shelfmark.environment.FLASK_PORT}";
      serverAliases = [ shelfmarkService.publicHost ];
      mtls.enable = true;
    };
  };

}
