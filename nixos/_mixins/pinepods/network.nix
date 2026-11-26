{
  config,
  lib,
  pinepodsModel,
  ...
}:
let
  inherit (pinepodsModel)
    cachePort
    cfg
    containerNetwork
    containerSubnet
    hostGateway
    ollamaTunnelPort
    ;
  ports = [
    5432
    cachePort
    ollamaTunnelPort
  ];
  proxyForPort =
    port:
    let
      portString = toString port;
      consumer =
        if port == ollamaTunnelPort then "podman-pinepods-ai.service" else "podman-pinepods.service";
    in
    lib.nameValuePair "pinepods-host-${portString}" {
      socket = {
        wantedBy = [ "sockets.target" ];
        requiredBy = [ consumer ];
        before = [ consumer ];
        listenStreams = [ "${hostGateway}:${portString}" ];
        # The bridge is created when Podman starts the first container.
        socketConfig.FreeBind = true;
      };
      service.serviceConfig = {
        Type = "notify";
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${portString}";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };
  proxies = builtins.listToAttrs (map proxyForPort ports);
in
{
  config = lib.mkIf (cfg != null) {
    virtualisation.podman.defaultNetwork.settings = {
      name = containerNetwork;
      # Preserve the ID of Podman's implicitly created default bridge.
      id = builtins.hashString "sha256" containerNetwork;
      network_interface = "podman0";
      dns_enabled = true;
      subnets = [
        {
          subnet = containerSubnet;
          gateway = hostGateway;
        }
      ];
    };

    # Plaintext stays on this host's private bridge. Backends keep their
    # loopback listeners, and only the mTLS tunnel crosses to the Ollama host.
    networking.firewall.interfaces.podman0.allowedTCPPorts = ports;
    systemd.sockets = lib.mapAttrs (_: proxy: proxy.socket) proxies;
    systemd.services = lib.mapAttrs (_: proxy: proxy.service) proxies;
  };
}
