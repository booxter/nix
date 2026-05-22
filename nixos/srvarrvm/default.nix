{
  inputs,
  hostInventory,
  ...
}:
let
  srvarrSpec = hostInventory.nixosHostSpecsByName.srvarr;
  wgBridgeAddress = srvarrSpec.wgNamespace.bridgeAddress;
  wgNamespaceAddress = srvarrSpec.wgNamespace.namespaceAddress;
  wgConservativeUploadRateMbit = 8;
  # Keep Transmission a little below the conservative tc floor so
  # Transmission's own scheduler remains the bottleneck and can favor
  # private-tracker torrents before traffic hits the kernel shaper.
  transmissionConservativeUploadLimitKBps = builtins.floor (
    (wgConservativeUploadRateMbit * 1000.0 / 8.0) * 0.95
  );
  transmissionNonPreferredLowPriorityRatio = 3.0;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgTimerDeps = {
    After = [ "wg.service" ];
  };
in
{
  _module.args = {
    inherit
      networkOnlineUnitDeps
      transmissionConservativeUploadLimitKBps
      transmissionNonPreferredLowPriorityRatio
      wgBridgeAddress
      wgConservativeUploadRateMbit
      wgNamespaceAddress
      wgTimerDeps
      wgUnitDepsBase
      ;
  };

  imports = [
    inputs.nixarr.nixosModules.default
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nfs.nix
    ./nightly-speedtest.nix
    ./sabnzbd.nix
    ./sabnzbd-exporter.nix
    ./transmission.nix
    ./transmission-torrent-cleaner.nix
    ./transmission-tracker-prioritizer.nix
    ./vpn.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;

  systemd.services.prowlarr.unitConfig = networkOnlineUnitDeps;

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
