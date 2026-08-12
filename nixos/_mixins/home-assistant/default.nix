{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.home-assistant;
in
{
  imports = [
    ./assertions.nix
    ./backups.nix
    ./bootstrap.nix
    ./service.nix
    ./web.nix
  ];

  options.host.home-assistant = {
    enable = lib.mkEnableOption "Home Assistant";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8123;
      readOnly = true;
      internal = true;
      description = "Loopback Home Assistant HTTP port.";
    };

    localUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.port}";
      readOnly = true;
      internal = true;
      description = "Loopback Home Assistant API URL.";
    };

    metrics.port = lib.mkOption {
      type = lib.types.port;
      default = 9346;
      readOnly = true;
      internal = true;
      description = "LAN-visible Home Assistant Prometheus endpoint port.";
    };

    backups.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to capture native Home Assistant backups with Restic.";
    };

    internal.tools = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkgs/home-assistant-tools { };
      readOnly = true;
      internal = true;
      description = "Home Assistant bootstrap and backup helper.";
    };
  };
}
