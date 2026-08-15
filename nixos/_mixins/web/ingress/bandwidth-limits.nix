{
  config,
  fleetWebServices,
  lib,
  ...
}:
let
  publicServices = builtins.filter (
    contribution: contribution.value.public.ingressHost == config.networking.hostName
  ) fleetWebServices.public;
  helpers = import ./bandwidth-limits/lib.nix { inherit lib; };
  routes = helpers.collect publicServices;
  proxyHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
  haproxyRouteConfig =
    route:
    let
      limit = route.bandwidthLimit;
      backend = lib.removePrefix "http://" route.upstream;
    in
    ''
      frontend ${route.id}_frontend
        bind 127.0.0.1:${toString limit.listenPort}
        default_backend ${route.id}_backend

      backend ${route.id}_backend
        stick-table type integer size 10 expire 1h store bytes_out_rate(1s)
        filter bwlim-out ${route.id} limit ${toString limit.bytesPerSecond} key be_id
        http-request set-var(txn.client_scope) str(external)
        http-request set-var(txn.client_scope) str(unlimited) if { req.hdr_ip(X-Real-IP) -m ip ${lib.concatStringsSep " " limit.unlimitedCidrs} }
        http-response set-bandwidth-limit ${route.id} if { var(txn.client_scope) -m str external }
        server ${route.id} ${backend}
    '';
in
{
  imports = [ ./bandwidth-limits/assertions.nix ];

  config = lib.mkIf (routes != [ ]) {
    services.nginx.virtualHosts = lib.mkMerge (
      map (route: {
        ${route.contribution.value.public.hostName}.locations.${route.location} = {
          proxyPass = "http://127.0.0.1:${toString route.bandwidthLimit.listenPort}";
          inherit (route) proxyWebsockets;
          recommendedProxySettings = false;
          extraConfig = proxyHeaders + ''
            proxy_buffering off;
          '';
        };
      }) routes
    );

    services.haproxy = {
      enable = true;
      config = ''
        global

        defaults
          mode http
          timeout connect 5s
          timeout client 1h
          timeout server 1h

        ${lib.concatMapStringsSep "\n" haproxyRouteConfig routes}
      '';
    };

    systemd.services.nginx = {
      wants = [ "haproxy.service" ];
      after = [ "haproxy.service" ];
    };
  };
}
