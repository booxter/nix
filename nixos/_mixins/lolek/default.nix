{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.lolek;
in
{
  imports = [
    inputs.lolek.nixosModules.default
    ./service.nix
  ];

  options.host.lolek = {
    enable = lib.mkEnableOption "Lolek Telegram media bot";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.lolek;
      description = "Lolek package to run.";
    };

    metrics = {
      internalPort = lib.mkOption {
        type = lib.types.port;
        default = 19568;
        description = "Loopback port where Lolek publishes Prometheus metrics.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9568;
        description = "mTLS port exposing Lolek metrics to Prometheus.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    host.autoUpgrade.claims.lolek.reboot = {
      cadence = "weekly";
      weekday = "Sat";
    };
  };
}
