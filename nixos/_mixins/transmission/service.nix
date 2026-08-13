{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg.enable && model.vpnNamespace != null) {
    services.transmission = {
      enable = true;
      package = cfg.package;
      group = cfg.group;
      home = cfg.stateDir;
      openPeerPorts = true;
      settings = {
        anti-brute-force-enabled = true;
        anti-brute-force-threshold = 10;
        cache-size-mb = 256;
        compact-view = true;
        download-dir = model.completeDir;
        download-queue-size = 100;
        encryption = 1;
        incomplete-dir = model.incompleteDir;
        lpd-enabled = false;
        message-level = 3;
        peer-port = cfg.vpn.peerPort;
        pex-enabled = true;
        port-forwarding-enabled = false;
        rpc-authentication-required = false;
        rpc-bind-address = model.vpnNamespace.namespaceAddress;
        rpc-host-whitelist = "${config.networking.hostName},${config.services.avahi.hostName}.local";
        rpc-whitelist = "127.0.0.1,192.168.*,10.*";
        sort-mode = "progress";
        umask = "002";
        watch-dir = model.watchDir;
        watch-dir-enabled = true;
      };
      user = cfg.user;
    };

    systemd.services.transmission.serviceConfig = {
      IOSchedulingPriority = 7;
      LimitNOFILE = 65536;
      Restart = "on-failure";
      # nixpkgs binds both download-dir and incomplete-dir into the service's
      # RootDirectory. When incomplete-dir is a child of download-dir, Linux
      # treats completion moves across those bind mount points as EXDEV, so
      # Transmission falls back to copy+delete for large files.
      # TODO: Report and fix this in the nixpkgs Transmission module.
      BindPaths = lib.mkForce (
        let
          settings = config.services.transmission.settings;
          incompleteDirNeedsOwnBind =
            settings.incomplete-dir-enabled
            && settings.incomplete-dir != settings.download-dir
            && !lib.hasPrefix "${settings.download-dir}/" settings.incomplete-dir;
        in
        [
          model.stateDir
          settings.download-dir
          "/run"
        ]
        ++ lib.optional incompleteDirNeedsOwnBind settings.incomplete-dir
        ++ lib.optional (
          settings.watch-dir-enabled && settings.trash-original-torrent-files
        ) settings.watch-dir
      );
    };
  };
}
