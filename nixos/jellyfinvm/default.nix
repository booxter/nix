{
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
    ./jellarr.nix
  ];

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  systemd.services.jellyfin.unitConfig.RequiresMountsFor = "/media";

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
      "au.ihar.dev" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "http://prox-srvarrvm:9292";
          proxyWebsockets = true;
        };
      };
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
