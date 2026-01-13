{
  lib,
  config,
  pkgs,
  inputs,
  hostname,
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
    inputs.nixarr.nixosModules.default
  ];

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."/data/media" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."/data/media" = media;

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
  systemd.services.audiobookshelf.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.bazarr.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.jellyseerr.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.lidarr.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.radarr.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.readarr.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.readarr-audiobook.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.sonarr.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.transmission.unitConfig.RequiresMountsFor = "/data/media";
  systemd.services.sabnzbd.unitConfig.RequiresMountsFor = "/data/media";

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
        rpc-host-whitelist = hostname;
      };
    };

  };

  systemd.services."update-dynamic-ip" = {
    after = [ "wg.service" ];
    wants = [ "wg.service" ];
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
      server.host = "0.0.0.0";
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
                      url = "http://prox-jellyfinvm:8096/";
                      icon = "sh:jellyfin";
                    }
                    {
                      title = "Jellyseerr";
                      url = "http://prox-srvarrvm:5055/";
                      icon = "sh:jellyseerr";
                    }
                    {
                      title = "Radarr";
                      url = "http://prox-srvarrvm:7878/";
                      icon = "sh:radarr";
                    }
                    {
                      title = "Sonarr";
                      url = "http://prox-srvarrvm:8989/";
                      icon = "sh:sonarr";
                    }
                    {
                      title = "Lidarr";
                      url = "http://prox-srvarrvm:8686/";
                      icon = "sh:lidarr";
                    }
                    {
                      title = "Audiobookshelf";
                      url = "http://prox-srvarrvm:9292/";
                      icon = "sh:audiobookshelf";
                    }
                    {
                      title = "Readarr";
                      url = "http://prox-srvarrvm:8787/";
                      icon = "sh:readarr";
                    }
                    {
                      title = "Readarr Audio";
                      url = "http://prox-srvarrvm:9494/";
                      icon = "sh:readarr";
                    }
                    {
                      title = "Bazarr";
                      url = "http://prox-srvarrvm:6767/";
                      icon = "sh:bazarr";
                    }
                    {
                      title = "Prowlarr";
                      url = "http://prox-srvarrvm:9696/";
                      icon = "sh:prowlarr";
                    }
                    {
                      title = "Transmission";
                      url = "http://prox-srvarrvm:9091/";
                      icon = "sh:transmission";
                    }
                    {
                      title = "SABNZB";
                      url = "http://prox-srvarrvm:6336/";
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
}
