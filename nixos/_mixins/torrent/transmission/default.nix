{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.transmission;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById.transmission;
  instance = service.instances.${hostname} or { };
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaDir = instance.mediaDir or "/var/lib/transmission-media";
  absolutePaths = builtins.mapAttrs (
    _: value: if builtins.isAttrs value then absolutePaths value else "${mediaDir}/${value}"
  );
  mediaPaths = absolutePaths mediaExport.layout.transmission;
  isMediaServer = mediaExport.server == hostname;
  vpnRequirement = instance.vpnConfinement or { };
  vpnProfile = hostInventory.egressVpns.${vpnRequirement.profile};
  peerPort = vpnRequirement.forwardedPort.port;
  stateDir = instance.dataDir or "/var/lib/transmission";
  vpnNamespaceAddress = vpnProfile.namespaceAddress;
  proxyHeaders = ''
    proxy_set_header Host ${hostname};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
  # Keep Transmission a little below the conservative tc floor so
  # Transmission's own scheduler remains the bottleneck and can favor
  # private-tracker torrents before traffic hits the kernel shaper.
  transmissionConservativeUploadLimitKBps = builtins.floor (
    (
      config.host.network.bandwidthTargets.${instance.bandwidthTargets.conservativeUpload}.rateMbit
      * 1000.0
      / 8.0
    )
    * 0.95
  );
in
{
  imports = [
    ./adaptive-upload.nix
    ./cleaner.nix
    ./tracker-policy.nix
  ];

  options.host.transmission.enable = lib.mkOption {
    type = lib.types.bool;
    default = hostInventory.serviceRunsOn hostname service;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns Transmission to this host.";
  };

  options.services.transmission.adaptiveUpload.enable =
    lib.mkEnableOption "adaptive Transmission upload limits"
    // {
      default = true;
    };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          instance ? adaptiveUpload
          && instance ? bandwidthTargets
          && instance ? dataDir
          && instance ? mediaDir
          && instance ? vpnConfinement;
        message = "The Transmission inventory instance must define storage, bandwidth, adaptive upload, and VPN policy.";
      }
      {
        assertion = vpnRequirement ? forwardedPort;
        message = "The Transmission VPN policy must allocate a forwarded peer port.";
      }
      {
        assertion = builtins.elem hostname mediaExport.clients;
        message = "The Transmission host must be an authorized media NFS client.";
      }
    ];

    sops.secrets.transmissionTrackerHosts = {
      key = "transmission/private_tracker_hosts";
      owner = "transmission";
      group = mediaExport.sharedGroup.name;
      mode = "0400";
    };

    services.transmission = {
      enable = true;
      group = mediaExport.sharedGroup.name;
      home = stateDir;
      openPeerPorts = true;
      settings = {
        anti-brute-force-enabled = true;
        anti-brute-force-threshold = 10;
        cache-size-mb = 256;
        compact-view = true;
        download-dir = mediaPaths.root;
        download-queue-size = 100;
        encryption = 1;
        incomplete-dir = mediaPaths.incomplete;
        lpd-enabled = false;
        message-level = 3;
        peer-port = peerPort;
        pex-enabled = true;
        port-forwarding-enabled = false;
        rpc-authentication-required = false;
        rpc-bind-address = vpnNamespaceAddress;
        rpc-host-whitelist = "${hostname},${config.services.avahi.hostName}.local";
        rpc-whitelist = "127.0.0.1,192.168.*,10.*";
        sort-mode = "progress";
        speed-limit-up = transmissionConservativeUploadLimitKBps;
        speed-limit-up-enabled = true;
        umask = "002";
        watch-dir = mediaPaths.watch;
        watch-dir-enabled = true;
      };
      user = "transmission";
    };

    services.adaptive-upload-policy.outputs.transmission.enable =
      config.services.transmission.adaptiveUpload.enable;

    host.nfs.mounts = lib.mkIf (!isMediaServer) {
      media = mediaDir;
    };

    host.nfs.qosLimits.nfs = {
      export = "media";
      bandwidthTarget = instance.bandwidthTargets.nfs;
    };

    users.users.${config.services.transmission.user}.uid =
      hostInventory.serviceAccounts.transmission.uid;

    systemd.services.transmission = {
      unitConfig.RequiresMountsFor = mediaDir;
      # Transmission is currently inheriting a soft RLIMIT_NOFILE of 1024,
      # which is too low for many active torrents and peers.
      serviceConfig = {
        IOSchedulingPriority = 7;
        LimitNOFILE = 65536;
        # Not sure why nixpkgs leaves Restart unset for Transmission, but this
        # is a long-running daemon and should come back after crashes.
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

    host.vpnConfinement.implementations.transmission = {
      serviceEnabled = true;
      systemdUnits = [ "transmission" ];
      bridgeTcpPorts = [ config.services.transmission.settings.rpc-port ];
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
          proxyPass = lib.mkForce "http://${vpnNamespaceAddress}:${toString config.services.transmission.settings.rpc-port}";
        };
      };

    host.internalService.services.transmission = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}";
      recommendedProxySettings = false;
      # Transmission RPC rejects the public LAN hostname, so preserve the
      # existing whitelisted host on the upstream hop.
      locationExtraConfig = proxyHeaders;
      probe = {
        upstreamPath = "/transmission/rpc";
        recommendedProxySettings = false;
        extraConfig = ''
          limit_except GET {
            deny all;
          }
          ${proxyHeaders}
        '';
      };
    };
  };
}
