{
  config,
  hostInventory,
  lib,
  wgConservativeUploadRateMbit,
  ...
}:
let
  wgNamespaceAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.namespaceAddress;
  # Keep Transmission a little below the conservative tc floor so
  # Transmission's own scheduler remains the bottleneck and can favor
  # private-tracker torrents before traffic hits the kernel shaper.
  transmissionConservativeUploadLimitKBps = builtins.floor (
    (wgConservativeUploadRateMbit * 1000.0 / 8.0) * 0.95
  );
in
{
  sops.secrets.transmissionTrackerHosts = {
    key = "transmission/private_tracker_hosts";
    owner = "transmission";
    group = "media";
    mode = "0400";
  };

  systemd.services.transmission = {
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
    vpn = {
      enable = true;
      configureNginx = false;
    };
    peerPort = 45486;
    extraSettings = {
      blocklist-enabled = false;
      cache-size-mb = 256;
      compact-view = true;
      download-queue-enabled = true;
      download-queue-size = 100;
      lpd-enabled = false;
      rpc-bind-address = wgNamespaceAddress;
      rpc-host-whitelist = "${config.networking.hostName},${config.services.avahi.hostName}.local";
      sort-mode = "progress";
      speed-limit-up = transmissionConservativeUploadLimitKBps;
      speed-limit-up-enabled = true;
      utp-enabled = true;
    };
  };

  # nixarr also DNATs the Transmission UI port from the LAN into the WireGuard
  # namespace. Keep only the SABnzbd port published until SABnzbd gets its own
  # HTTPS migration; Transmission should be reachable via loopback or the
  # dedicated internal HTTPS frontend only.
  vpnNamespaces.wg.portMappings = lib.mkForce [
    {
      from = config.nixarr.sabnzbd.guiPort;
      to = config.nixarr.sabnzbd.guiPort;
    }
  ];

  # nixarr hardcodes transmission nginx proxy to 192.168.15.1; override to wg subnet.
  services.nginx.virtualHosts."127.0.0.1:${toString config.nixarr.transmission.uiPort}" = {
    listen = lib.mkForce [
      {
        addr = "127.0.0.1";
        port = config.nixarr.transmission.uiPort;
      }
    ];
    locations."/" = {
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString config.nixarr.transmission.uiPort}";
    };
  };

  host.internalHttps.services.transmission = {
    enable = true;
    serverName = "tmission.${hostInventory.site.lan.domain}";
    serverAliases = [ "tmission" ];
    upstream = "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}";
    recommendedProxySettings = false;
    # Transmission RPC rejects the public LAN hostname, so preserve the
    # existing whitelisted host on the upstream hop.
    locationExtraConfig = ''
      proxy_set_header Host ${config.networking.hostName};
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Server $hostname;
    '';
  };
}
