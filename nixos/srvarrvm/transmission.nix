{
  config,
  hostInventory,
  lib,
  wgConservativeUploadRateMbit,
  ...
}:
let
  cfg = config.host.srvarr.services.transmission;
  mediaDir = config.host.srvarr.mediaDir;
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

  services.transmission = {
    enable = true;
    credentialsFile = "/dev/null";
    downloadDirPermissions = null;
    group = cfg.group;
    home = cfg.stateDir;
    openPeerPorts = true;
    openRPCPort = false;
    performanceNetParameters = false;
    settings = {
      anti-brute-force-enabled = true;
      anti-brute-force-threshold = 10;
      blocklist-enabled = false;
      blocklist-url = "https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz";
      cache-size-mb = 256;
      compact-view = true;
      dht-enabled = true;
      download-dir = "${mediaDir}/torrents";
      download-queue-enabled = true;
      download-queue-size = 100;
      encryption = 1;
      incomplete-dir = "${mediaDir}/torrents/.incomplete";
      incomplete-dir-enabled = true;
      lpd-enabled = false;
      message-level = 3;
      peer-port = cfg.peerPort;
      peer-port-random-high = 65535;
      peer-port-random-low = 65535;
      peer-port-random-on-start = false;
      pex-enabled = true;
      port-forwarding-enabled = false;
      rpc-authentication-required = false;
      rpc-bind-address = wgNamespaceAddress;
      rpc-host-whitelist = "${config.networking.hostName},${config.services.avahi.hostName}.local";
      rpc-port = cfg.port;
      rpc-whitelist = "127.0.0.1,192.168.*,10.*";
      rpc-whitelist-enabled = true;
      script-torrent-done-enabled = false;
      script-torrent-done-filename = null;
      sort-mode = "progress";
      speed-limit-up = transmissionConservativeUploadLimitKBps;
      speed-limit-up-enabled = true;
      trash-original-torrent-files = false;
      umask = "002";
      utp-enabled = true;
      watch-dir = "${mediaDir}/torrents/.watch";
      watch-dir-enabled = true;
    };
    user = cfg.user;
    webHome = null;
  };

  systemd.services.transmission = {
    environment.TR_TRACKER_PRIORITY_FILE = config.sops.secrets.transmissionTrackerHosts.path;
    # Transmission is currently inheriting a soft RLIMIT_NOFILE of 1024, which
    # is too low for many active torrents and peers.
    serviceConfig = {
      IOSchedulingPriority = 7;
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
    vpnConfinement = {
      enable = true;
      vpnNamespace = "wg";
    };
  };

  vpnNamespaces.wg.openVPNPorts = [
    {
      port = cfg.peerPort;
      protocol = "both";
    }
  ];

  host.vpnNamespaceBridgeAccess.tcpPorts = [ config.host.srvarr.services.transmission.port ];

  # Keep the host-local helper on loopback, but target the actual namespace
  # address directly instead of the old fixed proxy address.
  services.nginx.virtualHosts."127.0.0.1:${toString config.host.srvarr.services.transmission.port}" = {
    listen = lib.mkForce [
      {
        addr = "127.0.0.1";
        port = config.host.srvarr.services.transmission.port;
      }
    ];
    locations."/" = {
      recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString config.host.srvarr.services.transmission.port}";
    };
  };

  host.internalHttps.services.transmission = {
    enable = true;
    serverName = "tmission.${hostInventory.site.lan.domain}";
    serverAliases = [ "tmission" ];
    upstream = "http://127.0.0.1:${toString config.host.srvarr.services.transmission.port}";
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
