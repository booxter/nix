{
  lib,
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

  services.tailscale.enable = lib.mkForce false;

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

    jellyseerr.enable = true; # requests
    prowlarr.enable = true; # indexer
    radarr.enable = true; # movies
    #sonarr.enable = true; # tv shows
    #lidarr.enable = true; # music
    bazarr.enable = true; # subtitles

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
