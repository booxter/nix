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
  nixarrSource = builtins.path {
    path = ../../vendor/nixarr-source;
    name = "source";
  };
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
    "${nixarrSource}/nixarr"
    inputs.vpnconfinement.nixosModules.default
    ./contract.nix
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nfs.nix
    ./sabnzbd.nix
    ./sabnzbd-exporter.nix
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

  nixarr = {
    enable = true;
    seerr = {
      enable = true;
      openFirewall = false;
    };
    shelfmark = {
      enable = true;
      host = "127.0.0.1";
      openFirewall = false;
    };
    bazarr = {
      enable = true;
      # TODO: Upstream a nixarr.bazarr bind-address/host knob. The current
      # nixarr Bazarr module only passes --config/--port/--no-update, so we
      # keep the process bound broadly for now and rely on the firewall plus
      # the HTTPS frontend to retire plain LAN access.
      openFirewall = false;
    };
    audiobookshelf = {
      enable = true;
      host = "127.0.0.1";
      openFirewall = false;
    };

  };

  services = {
    radarr = {
      enable = true;
      dataDir = config.host.srvarr.services.radarr.stateDir;
      user = config.host.srvarr.services.radarr.user;
      group = config.host.srvarr.services.radarr.group;
      openFirewall = false;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
          port = config.host.srvarr.services.radarr.port;
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
      environmentFiles = [ ];
    };
    sonarr = {
      enable = true;
      dataDir = config.host.srvarr.services.sonarr.stateDir;
      user = config.host.srvarr.services.sonarr.user;
      group = config.host.srvarr.services.sonarr.group;
      openFirewall = false;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
          port = config.host.srvarr.services.sonarr.port;
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
      environmentFiles = [ ];
    };
    lidarr = {
      enable = true;
      dataDir = config.host.srvarr.services.lidarr.stateDir;
      user = config.host.srvarr.services.lidarr.user;
      group = config.host.srvarr.services.lidarr.group;
      openFirewall = false;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
          port = config.host.srvarr.services.lidarr.port;
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
      environmentFiles = [ ];
    };
    prowlarr = {
      enable = true;
      openFirewall = false;
      settings = {
        log.analyticsEnabled = false;
        server = {
          bindaddress = "127.0.0.1";
          port = config.host.srvarr.services.prowlarr.port;
        };
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
      environmentFiles = [ ];
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

  # Both VPN-confined UIs are now fronted either by localhost-only proxies or
  # dedicated internal HTTPS vhosts. Retire nixarr's default LAN DNAT for the
  # UI ports entirely.
  vpnNamespaces.wg.portMappings = inputs.nixpkgs.lib.mkForce [ ];

  host.internalHttps.services = {
    radarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.radarr.port}";
    };
    sonarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.sonarr.port}";
    };
    lidarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.lidarr.port}";
    };
    bazarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.bazarr.port}";
    };
    prowlarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.prowlarr.port}";
    };
    jellyseerr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.seerr.port}";
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
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.audiobookshelf.port}";
      serverAliases = [ audiobookshelfService.publicHost ];
      mtls.enable = true;
    };
    shelfmark = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.shelfmark.port}";
      serverAliases = [ shelfmarkService.publicHost ];
      mtls.enable = true;
    };
  };

  host.observability.client.mtlsClients."jellyfin-upload-policy".enable = true;

}
