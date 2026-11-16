{ config, lib, ... }:
{
  config = lib.mkIf (config.host.observability.server != null) {
    services.tempo = {
      enable = true;
      settings = import ./settings.nix;
    };

    # Only ingestion is exposed remotely; Grafana queries Tempo over loopback.
    host.web.services.tempo = {
      upstream = "http://127.0.0.1:4319";
      internal.locationExtraConfig = ''
        client_max_body_size 4m;
        proxy_request_buffering off;
      '';
    };

    systemd.services.tempo = {
      environment.GOMEMLIMIT = "3GiB";
      serviceConfig = {
        MemoryHigh = "3G";
        MemoryMax = "4G";
        CPUQuota = "200%";
      };
    };
  };
}
