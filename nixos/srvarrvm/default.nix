{
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
      openFirewall = true;
    };
    prowlarr = {
      enable = true;
      openFirewall = true;
    };
    radarr = {
      enable = true;
      openFirewall = true;
    };
    lidarr = {
      enable = true;
      openFirewall = true;
    };
    shelfmark = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };
    sonarr = {
      enable = true;
      openFirewall = true;
    };
    bazarr = {
      enable = true;
      openFirewall = true;
    };
    audiobookshelf = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };

  };

}
