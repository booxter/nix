{
  config,
  lib,
  pkgs,
  ...
}:
let
  aurralPort = 3001;
  lidarrPort = config.nixarr.lidarr.port;
  mediaPath = config.nixarr.mediaDir;
  aurralStateDir = "${config.nixarr.stateDir}/aurral";
  aurralFlowDir = "${mediaPath}/library/flows";
  wgNamespace = "wg";
  wgNamespaceVeth = "veth-${wgNamespace}";
  wgNamespaceAddress = config.vpnNamespaces.${wgNamespace}.namespaceAddress;
  wgBridgeAddress = config.vpnNamespaces.${wgNamespace}.bridgeAddress;
  aurralUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [
      "network-online.target"
      "${wgNamespace}.service"
      "aurral-lidarr-localhost-proxy.service"
    ];
    BindsTo = [ "${wgNamespace}.service" ];
    PartOf = [ "${wgNamespace}.service" ];
    RequiresMountsFor = mediaPath;
  };
in
{
  users.groups.aurral = { };
  users.users.aurral = {
    isSystemUser = true;
    group = "aurral";
    extraGroups = [ "media" ];
  };

  systemd.tmpfiles.rules = [
    "d ${aurralStateDir} 0750 aurral aurral - -"
    "z ${aurralStateDir} 0750 aurral aurral - -"
  ];

  networking.firewall.allowedTCPPorts = [ aurralPort ];

  services.nginx.virtualHosts."127.0.0.1:${toString aurralPort}" = {
    listen = [
      {
        addr = "0.0.0.0";
        port = aurralPort;
      }
    ];
    locations."/" = {
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString aurralPort}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  systemd.services.aurral-lidarr-localhost-proxy = {
    description = "Prepare Aurral networking inside the VPN namespace";
    wantedBy = [ "multi-user.target" ];
    before = [ "aurral.service" ];
    unitConfig = {
      Wants = [ "${wgNamespace}.service" ];
      After = [ "${wgNamespace}.service" ];
      BindsTo = [ "${wgNamespace}.service" ];
      PartOf = [ "${wgNamespace}.service" ];
    };
    path = [
      pkgs.iproute2
      pkgs.iptables
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "aurral-lidarr-localhost-proxy-start" ''
        set -euo pipefail

        ip netns exec ${wgNamespace} iptables -w -C INPUT \
          -i ${wgNamespaceVeth} -p tcp --dport ${toString aurralPort} \
          -j ACCEPT 2>/dev/null || \
          ip netns exec ${wgNamespace} iptables -w -A INPUT \
            -i ${wgNamespaceVeth} -p tcp --dport ${toString aurralPort} \
            -j ACCEPT

        ip netns exec ${wgNamespace} iptables -w -t nat -C OUTPUT \
          -p tcp -d 127.0.0.0/8 --dport ${toString lidarrPort} \
          -j DNAT --to-destination ${wgBridgeAddress}:${toString lidarrPort} \
          2>/dev/null || \
          ip netns exec ${wgNamespace} iptables -w -t nat -A OUTPUT \
            -p tcp -d 127.0.0.0/8 --dport ${toString lidarrPort} \
            -j DNAT --to-destination ${wgBridgeAddress}:${toString lidarrPort}
      '';
      ExecStop = pkgs.writeShellScript "aurral-lidarr-localhost-proxy-stop" ''
        set -euo pipefail

        while ip netns exec ${wgNamespace} iptables -w -C INPUT \
          -i ${wgNamespaceVeth} -p tcp --dport ${toString aurralPort} \
          -j ACCEPT 2>/dev/null; do
          ip netns exec ${wgNamespace} iptables -w -D INPUT \
            -i ${wgNamespaceVeth} -p tcp --dport ${toString aurralPort} \
            -j ACCEPT
        done

        while ip netns exec ${wgNamespace} iptables -w -t nat -C OUTPUT \
          -p tcp -d 127.0.0.0/8 --dport ${toString lidarrPort} \
          -j DNAT --to-destination ${wgBridgeAddress}:${toString lidarrPort} \
          2>/dev/null; do
          ip netns exec ${wgNamespace} iptables -w -t nat -D OUTPUT \
            -p tcp -d 127.0.0.0/8 --dport ${toString lidarrPort} \
            -j DNAT --to-destination ${wgBridgeAddress}:${toString lidarrPort}
        done
      '';
    };
  };

  systemd.services.aurral = {
    description = "Aurral music discovery and flow download service";
    wantedBy = [ "multi-user.target" ];
    unitConfig = aurralUnitDeps;
    path = [ pkgs.coreutils ];
    environment = {
      AURRAL_DATA_DIR = aurralStateDir;
      DOWNLOAD_FOLDER = aurralFlowDir;
      WEEKLY_FLOW_FOLDER = aurralFlowDir;
      PORT = toString aurralPort;
      # Public access traverses beast nginx first and then the local srvarr
      # nginx proxy in front of the app.
      TRUST_PROXY = "2";
    };
    serviceConfig = {
      ExecStart = lib.getExe pkgs.aurral;
      User = "aurral";
      Group = "aurral";
      WorkingDirectory = aurralStateDir;
      UMask = "0007";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 65536;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        aurralStateDir
        aurralFlowDir
      ];
      ProtectHome = true;
      ProtectHostname = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      LockPersonality = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      RemoveIPC = true;
      NetworkNamespacePath = "/run/netns/${wgNamespace}";
      BindReadOnlyPaths = [ "/etc/netns/${wgNamespace}/resolv.conf:/etc/resolv.conf:norbind" ];
    };
  };
}
