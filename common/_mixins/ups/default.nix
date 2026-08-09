{
  config,
  facts,
  hostSpec,
  lib,
  ...
}:
let
  cfg = config.host.ups;
in
{
  options.host.ups = {
    server = {
      enable = lib.mkEnableOption "local UPS server" // {
        default = builtins.elem hostSpec.name facts.ups.servers;
      };

      description = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Human-readable description of the locally attached UPS.";
      };
    };

    client.server = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = facts.ups.clients.${hostSpec.name} or null;
      description = "Host providing the UPS service monitored by this host.";
    };

    shutdown = {
      critical = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to wait for low battery instead of using a shutdown timer.";
      };

      delaySeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default =
          if cfg.client.server == null then
            600
          else if config.host.isVM then
            450
          else
            900;
        description = "Seconds to remain on battery before shutting down.";
      };
    };
  };

  config.assertions = [
    {
      assertion = !cfg.server.enable || cfg.server.description != null;
      message = "host.ups.server.description is required when the UPS server is enabled";
    }
  ];
}
