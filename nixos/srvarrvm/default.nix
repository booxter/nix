{
  config,
  inputs,
  ...
}:
let
  wgConservativeUploadRateMbit = 8;
  transmissionNonPreferredLowPriorityRatio = 3.0;
  transmissionNonPreferredPauseRatio = 6.0;
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
    inputs.nixarr.nixosModules.default
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
    prowlarr = {
      enable = true;
      openFirewall = false;
    };
    radarr = {
      enable = true;
      openFirewall = false;
    };
    lidarr = {
      enable = true;
      openFirewall = false;
    };
    shelfmark = {
      enable = true;
      host = "127.0.0.1";
      openFirewall = false;
    };
    sonarr = {
      enable = true;
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
    radarr.settings.server.bindaddress = "127.0.0.1";
    sonarr.settings.server.bindaddress = "127.0.0.1";
    lidarr.settings.server.bindaddress = "127.0.0.1";
    prowlarr.settings.server.bindaddress = "127.0.0.1";
  };

  # Both VPN-confined UIs are now fronted either by localhost-only proxies or
  # dedicated internal HTTPS vhosts. Retire nixarr's default LAN DNAT for the
  # UI ports entirely.
  vpnNamespaces.wg.portMappings = inputs.nixpkgs.lib.mkForce [ ];

  host.internalHttps.services = {
    radarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.radarr.port}";
    };
    sonarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.sonarr.port}";
    };
    lidarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.lidarr.port}";
    };
    bazarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.bazarr.port}";
    };
    prowlarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.prowlarr.port}";
    };
    jellyseerr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
      mtls.enable = true;
    };
    aurral = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.systemd.services.aurral.environment.PORT}";
      mtls.enable = true;
    };
    audiobookshelf = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.audiobookshelf.port}";
      mtls.enable = true;
    };
    shelfmark = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.nixarr.shelfmark.port}";
      mtls.enable = true;
    };
  };

  host.observability.client.prometheusMtlsClients."jellyfin-upload-policy".enable = true;

}
