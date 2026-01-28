{
  lib,
  config,
  pkgs,
  inputs,
  hostname,
  ...
}:
let
  mediaPath = "/data/media";
  media = {
    device = "nas-lab:/volume2/Media";
    fsType = "nfs";
  };
  wgUnitDepsBase = {
    After = [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgUnitDepsWithMount = wgUnitDepsBase // requiresMediaMount;
  requiresMediaMount = {
    RequiresMountsFor = mediaPath;
  };
in
{
  imports = [
    inputs.nixarr.nixosModules.default
  ];

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."${mediaPath}" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."${mediaPath}" = media;

  users.users.${config.util-nixarr.globals.bazarr.user}.extraGroups = [ "media" ];

  systemd.services.radarr = {
    serviceConfig = {
      UMask = "0002";
    };
  };

  systemd.services.sonarr = {
    serviceConfig = {
      UMask = "0002";
    };
  };

  systemd.services.bazarr = {
    serviceConfig = {
      UMask = "0002";
    };
  };

  # make all services that r/w to nfs mount require the mount
  systemd.services.audiobookshelf.unitConfig = requiresMediaMount;
  systemd.services.bazarr.unitConfig = requiresMediaMount;
  systemd.services.jellyseerr.unitConfig = requiresMediaMount;
  systemd.services.lidarr.unitConfig = requiresMediaMount;
  systemd.services.radarr.unitConfig = requiresMediaMount;
  systemd.services.readarr.unitConfig = requiresMediaMount;
  systemd.services.readarr-audiobook.unitConfig = requiresMediaMount;
  systemd.services.sonarr.unitConfig = requiresMediaMount;
  systemd.services.transmission.unitConfig = wgUnitDepsWithMount;
  systemd.services.sabnzbd.unitConfig = wgUnitDepsWithMount;

  # Keep download dir locally to ease load on network and storage
  systemd.services.sabnzbd.serviceConfig = {
    ExecStartPre =
      let
        fix-incomplete-dir = pkgs.writeShellApplication {
          name = "fix-incomplete-dir";
          text = ''
            sed -i 's|download_dir = .*|download_dir = /data/.cache/usenet/incomplete|g' /var/lib/sabnzbd/sabnzbd.ini
          '';
        };
      in
      [
        (lib.getExe' fix-incomplete-dir "fix-incomplete-dir")
      ];
  };
  services.sabnzbd.allowConfigWrite = true;

  nixarr = {
    enable = true;
    # TODO: reconcile 192.168.15.1 (switch) address being used
    # for vpn routing?
    vpn = {
      enable = true;
      wgConf = "/data/.secret/vpn/wg.conf";
      accessibleFrom = [
        "192.168.0.0/16"
      ];
    };

    jellyseerr.enable = true;
    prowlarr.enable = true;
    radarr.enable = true;
    lidarr.enable = true;
    readarr.enable = true;
    readarr-audiobook.enable = true;
    sonarr.enable = true;
    bazarr.enable = true;
    audiobookshelf.enable = true;

    # usenet
    sabnzbd = {
      enable = true;
      vpn.enable = true;
    };

    # torrent
    transmission = {
      enable = true;
      vpn.enable = true;
      peerPort = 45486;
      extraSettings = {
        rpc-host-whitelist = "${hostname},${config.services.avahi.hostName}.local";
      };
    };

  };

  systemd.services."update-dynamic-ip" = {
    unitConfig = wgUnitDepsBase;
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        let
          cookiePath = "/data/.secret/mam.cookies";
        in
        "${pkgs.curl}/bin/curl -c ${cookiePath} -b ${cookiePath} https://t.myanonamouse.net/json/dynamicSeedbox.php";
    };
    vpnconfinement = {
      enable = true;
      vpnnamespace = "wg";
    };
  };

  # expose to lan
  systemd.services.audiobookshelf.serviceConfig.ExecStart =
    lib.mkForce "${config.nixarr.audiobookshelf.package}/bin/audiobookshelf --host 0.0.0.0 --port ${toString config.nixarr.audiobookshelf.port}";
  networking.firewall.allowedTCPPorts = [ config.nixarr.audiobookshelf.port ];

  services.glance = {
    enable = true;
    openFirewall = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 80;
      };
      pages = [
        {
          name = "Startpage";
          width = "slim";
          hide-desktop-navigation = true;
          center-vertically = true;
          columns = [
            {
              size = "full";
              widgets = [
                {
                  type = "search";
                  autofocus = true;
                }
                {
                  type = "monitor";
                  cache = "1m";
                  title = "Services";

                  # TODO: extract port numbers from config
                  sites = [
                    {
                      title = "Jellyfin";
                      url = "https://jf.ihar.dev";
                      icon = "sh:jellyfin";
                    }
                    {
                      title = "Jellyseerr";
                      url = "https://js.ihar.dev";
                      icon = "sh:jellyseerr";
                    }
                    {
                      title = "Radarr";
                      url = "http://srvarr.local:7878/";
                      icon = "sh:radarr";
                    }
                    {
                      title = "Sonarr";
                      url = "http://srvarr.local:8989/";
                      icon = "sh:sonarr";
                    }
                    {
                      title = "Lidarr";
                      url = "http://srvarr.local:8686/";
                      icon = "sh:lidarr";
                    }
                    {
                      title = "Audiobookshelf";
                      url = "http://srvarr.local:9292/";
                      icon = "sh:audiobookshelf";
                    }
                    {
                      title = "Readarr";
                      url = "http://srvarr.local:8787/";
                      icon = "sh:readarr";
                    }
                    {
                      title = "Readarr Audio";
                      url = "http://srvarr.local:9494/";
                      icon = "sh:readarr";
                    }
                    {
                      title = "Bazarr";
                      url = "http://srvarr.local:6767/";
                      icon = "sh:bazarr";
                    }
                    {
                      title = "Prowlarr";
                      url = "http://srvarr.local:9696/";
                      icon = "sh:prowlarr";
                    }
                    {
                      title = "Transmission";
                      url = "http://srvarr.local:9091/";
                      icon = "sh:transmission";
                    }
                    {
                      title = "SABNZB";
                      url = "http://srvarr.local:6336/";
                      icon = "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg";
                    }
                    {
                      title = "NAS";
                      url = "https://nas-lab:8001/";
                      icon = "di:asustor";
                      allow-insecure = true;
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # Allow glance to bind to lower port, 80
  systemd.services.glance.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    NoNewPrivileges = false;
    PrivateUsers = lib.mkForce false;
  };
}
