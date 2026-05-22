{
  config,
  hostname,
  lib,
  transmissionConservativeUploadLimitKBps,
  wgNamespaceAddress,
  wgUnitDepsWithMount,
  ...
}:
{
  sops.secrets.transmissionTrackerHosts = {
    key = "transmission/private_tracker_hosts";
    owner = "transmission";
    group = "media";
    mode = "0400";
  };

  systemd.services.transmission = {
    unitConfig = wgUnitDepsWithMount;
    environment.TR_TRACKER_PRIORITY_FILE = config.sops.secrets.transmissionTrackerHosts.path;
    # Transmission is currently inheriting a soft RLIMIT_NOFILE of 1024, which
    # is too low for many active torrents and peers.
    serviceConfig = {
      LimitNOFILE = 65536;
      # Not sure why nixpkgs leaves Restart unset for Transmission, but this is
      # a long-running daemon and should come back after crashes.
      Restart = "on-failure";
      # nixpkgs binds both download-dir and incomplete-dir into the service's
      # RootDirectory. When incomplete-dir is a child of download-dir, Linux
      # treats completion moves across those bind mount points as EXDEV, so
      # Transmission falls back to copy+delete for large files. Report/fix
      # upstream in the nixpkgs Transmission module.
      BindPaths = lib.mkForce (
        let
          transmissionSettingsDir = "${config.services.transmission.home}/.config/transmission-daemon";
          transmissionDownloadDir = config.services.transmission.settings.download-dir;
          transmissionIncompleteDir = config.services.transmission.settings.incomplete-dir;
          transmissionWatchDir = config.services.transmission.settings.watch-dir;
          incompleteDirNeedsOwnBind =
            config.services.transmission.settings.incomplete-dir-enabled
            && transmissionIncompleteDir != transmissionDownloadDir
            && !lib.hasPrefix "${transmissionDownloadDir}/" transmissionIncompleteDir;
        in
        [
          transmissionSettingsDir
          transmissionDownloadDir
          "/run"
        ]
        ++ lib.optional incompleteDirNeedsOwnBind transmissionIncompleteDir
        ++ lib.optional (
          config.services.transmission.settings.watch-dir-enabled
          && config.services.transmission.settings.trash-original-torrent-files
        ) transmissionWatchDir
      );
    };
  };

  nixarr.transmission = {
    enable = true;
    vpn.enable = true;
    peerPort = 45486;
    extraSettings = {
      blocklist-enabled = false;
      cache-size-mb = 256;
      compact-view = true;
      download-queue-enabled = true;
      download-queue-size = 100;
      lpd-enabled = false;
      rpc-bind-address = wgNamespaceAddress;
      rpc-host-whitelist = "${hostname},${config.services.avahi.hostName}.local";
      sort-mode = "progress";
      speed-limit-up = transmissionConservativeUploadLimitKBps;
      speed-limit-up-enabled = true;
      utp-enabled = true;
    };
  };

  # nixarr hardcodes transmission nginx proxy to 192.168.15.1; override to wg subnet.
  services.nginx.virtualHosts."127.0.0.1:${toString config.nixarr.transmission.uiPort}".locations."/" =
    {
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString config.nixarr.transmission.uiPort}";
    };
}
