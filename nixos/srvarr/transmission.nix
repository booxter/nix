{
  config,
  lib,
  ...
}:
let
  mediaDir = config.host.storage.claims.media.mountPoint;
  vpnClient = config.host.vpn.clients.transmission;
  vpnNamespace = config.host.vpn.namespaces.${vpnClient.namespace};
  peerPort = vpnClient.forwardedPorts.peer.port;
  stateDir = "/data/.state/nixarr/transmission";
  transmissionStateDir = "${stateDir}/.config/transmission-daemon";
  tuning = config.host.srvarrTuning;
  # Keep Transmission a little below the conservative tc floor so
  # Transmission's own scheduler remains the bottleneck and can favor
  # private-tracker torrents before traffic hits the kernel shaper.
  transmissionConservativeUploadLimitKBps = builtins.floor (
    (tuning.wgConservativeUploadRateMbit * 1000.0 / 8.0) * 0.95
  );
in
{
  imports = [
    ./transmission-torrent-cleaner.nix
    ./transmission-prioritizer.nix
  ];

  host.backups.sources.transmission = {
    title = "Transmission";
    paths = [ transmissionStateDir ];
    exclude = [
      "${transmissionStateDir}/*.tmp.*"
      "${transmissionStateDir}/blocklists"
      "${transmissionStateDir}/blocklists/**"
      "${transmissionStateDir}/dht.dat"
      "${transmissionStateDir}/settings.json"
      "${transmissionStateDir}/stats.json"
    ];
  };

  host.storage.claims.media.directories =
    builtins.listToAttrs (
      map
        (path: {
          name = "torrents/${path}";
          value = {
            owner = "transmission";
            mode = "0755";
          };
        })
        [
          ".incomplete"
          ".watch"
          "lidarr"
          "manual"
          "radarr"
          "sonarr"
        ]
    )
    // {
      torrents = {
        owner = "transmission";
        mode = "0755";
      };
    };
  host.storage.claims.media.attachments.transmission.unit = "transmission";

  sops.secrets.transmissionTrackerHosts = {
    key = "transmission/private_tracker_hosts";
    owner = "transmission";
    group = "media";
    mode = "0400";
  };

  services.transmission = {
    enable = true;
    group = "media";
    home = stateDir;
    openPeerPorts = true;
    settings = {
      anti-brute-force-enabled = true;
      anti-brute-force-threshold = 10;
      cache-size-mb = 256;
      compact-view = true;
      download-dir = "${mediaDir}/torrents";
      download-queue-size = 100;
      encryption = 1;
      incomplete-dir = "${mediaDir}/torrents/.incomplete";
      lpd-enabled = false;
      message-level = 3;
      peer-port = peerPort;
      pex-enabled = true;
      port-forwarding-enabled = false;
      rpc-authentication-required = false;
      rpc-bind-address = vpnNamespace.namespaceAddress;
      rpc-host-whitelist = "${config.networking.hostName},${config.services.avahi.hostName}.local";
      rpc-whitelist = "127.0.0.1,192.168.*,10.*";
      sort-mode = "progress";
      speed-limit-up = transmissionConservativeUploadLimitKBps;
      speed-limit-up-enabled = true;
      umask = "002";
      watch-dir = "${mediaDir}/torrents/.watch";
      watch-dir-enabled = true;
    };
    user = "transmission";
  };

  host.downloads.clients.transmission = {
    kind = "torrent";
    implementation = "transmission";
    endpoint = "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}/transmission/rpc";
    storageDefaults = {
      owner = "transmission";
      group = "media";
      mode = "0755";
    };
  };

  systemd.services.transmission = {
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
          transmissionDownloadDir = config.services.transmission.settings.download-dir;
          transmissionIncompleteDir = config.services.transmission.settings.incomplete-dir;
          transmissionWatchDir = config.services.transmission.settings.watch-dir;
          incompleteDirNeedsOwnBind =
            config.services.transmission.settings.incomplete-dir-enabled
            && transmissionIncompleteDir != transmissionDownloadDir
            && !lib.hasPrefix "${transmissionDownloadDir}/" transmissionIncompleteDir;
        in
        [
          transmissionStateDir
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

  host.vpn.clients.transmission = {
    namespace = "wg";
    bridgeTcpPorts = [ config.services.transmission.settings.rpc-port ];
    forwardedPorts.peer = {
      port = 45486;
      protocol = "both";
    };
  };

  # Keep the host-local helper on loopback, but target the actual namespace
  # address directly instead of the old fixed proxy address.
  services.nginx.virtualHosts."127.0.0.1:${toString config.services.transmission.settings.rpc-port}" =
    {
      listen = lib.mkForce [
        {
          addr = "127.0.0.1";
          port = config.services.transmission.settings.rpc-port;
        }
      ];
      locations."/" = {
        recommendedProxySettings = true;
        proxyWebsockets = true;
        proxyPass = lib.mkForce "http://${vpnNamespace.namespaceAddress}:${toString config.services.transmission.settings.rpc-port}";
      };
    };

  host.web.services.transmission = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}";
    health = {
      frontend = {
        enable = true;
        path = "/oauth2/sign_in";
      };
      backend = {
        enable = true;
        path = "/__probe/transmission-rpc";
        module = "http_service_409";
      };
    };
    presentation.dashboard = {
      enable = true;
      section = "media-admin";
    };
    internal = {
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
  };
}
