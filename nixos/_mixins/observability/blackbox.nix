{
  config,
  lib,
  pkgs,
  ...
}:
let
  observabilityCfg = config.host.observability;
  cfg = observabilityCfg.blackbox;
  httpService = {
    http = {
      follow_redirects = true;
      preferred_ip_protocol = "ip4";
    };
    prober = "http";
    timeout = "5s";
  };
in
{
  options.host.observability.blackbox = {
    enable = lib.mkEnableOption "host-side blackbox exporter probes";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the local Prometheus blackbox exporter to bind.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 19115;
      description = "Loopback port for the local Prometheus blackbox exporter.";
    };

    modules = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = "Named probe modules passed to the Prometheus blackbox exporter.";
    };

    baseModules = lib.mkOption {
      type = with lib.types; attrsOf anything;
      readOnly = true;
      internal = true;
      description = "Built-in blackbox probe modules available to derived module definitions.";
    };

    remote = {
      enable = lib.mkEnableOption "mTLS-protected remote access to the blackbox exporter";

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address for the remote mTLS endpoint to bind.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9115;
        description = "LAN-visible port for the mTLS-protected blackbox exporter endpoint.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to open the firewall for the remote mTLS endpoint.";
      };
    };
  };

  config = lib.mkMerge [
    {
      host.observability.blackbox.baseModules = {
        dns_udp = {
          dns = {
            preferred_ip_protocol = "ip4";
            query_name = "example.com";
            query_type = "A";
            transport_protocol = "udp";
            valid_rcodes = [ "NOERROR" ];
          };
          prober = "dns";
          timeout = "5s";
        };

        http_service = httpService;

        http_service_409 = httpService // {
          http = httpService.http // {
            valid_status_codes = [ 409 ];
          };
        };

        icmp_ipv4 = {
          icmp.preferred_ip_protocol = "ip4";
          prober = "icmp";
          timeout = "3s";
        };

        tcp_connect_ipv4 = {
          prober = "tcp";
          tcp.preferred_ip_protocol = "ip4";
          timeout = "3s";
        };
      };

      host.observability.blackbox.modules = cfg.baseModules;
    }
    (lib.mkIf (observabilityCfg.enable && cfg.enable) {
      services.prometheus.exporters.blackbox = {
        enable = true;
        inherit (cfg) listenAddress port;
        configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
          inherit (cfg) modules;
        };
      };
    })
    (lib.mkIf cfg.remote.enable {
      host.observability = {
        blackbox.enable = true;
        prometheusEndpoints.blackbox = {
          enable = true;
          listenAddress = cfg.remote.listenAddress;
          port = cfg.remote.port;
          path = "/probe";
          upstream = "http://${cfg.listenAddress}:${toString cfg.port}/probe";
          openFirewall = cfg.remote.openFirewall;
        };
      };
    })
  ];
}
