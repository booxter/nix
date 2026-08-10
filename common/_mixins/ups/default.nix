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
  imports = [ ./assertions.nix ];

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

      baseDelaySeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "Shutdown delay assigned to the UPS server before dependency stages are subtracted.";
      };

      separationSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 150;
        description = "Seconds separating each shutdown dependency stage.";
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

    };
  };

  config.host.power.shutdown.before.ups-server = lib.optional (
    cfg.client.server != null
  ) cfg.client.server;
}
