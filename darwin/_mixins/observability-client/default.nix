{ config, lib, ... }:
let
  cfg = config.host.observability.client;
in
{
  options.host.observability.client = {
    enable = lib.mkEnableOption "host-side observability client services";
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "0.0.0.0";
    };
  };
}
