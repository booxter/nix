{
  config,
  lib,
  ...
}:
let
  cfg = config.host.vikunja;
in
{
  imports = [
    ./backups.nix
    ./secrets.nix
    ./service.nix
    ./web.nix
  ];

  options.host.vikunja = {
    enable = lib.mkEnableOption "Vikunja";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3456;
      readOnly = true;
      internal = true;
      description = "Loopback Vikunja HTTP port.";
    };

    localUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.port}";
      readOnly = true;
      internal = true;
      description = "Loopback Vikunja API URL.";
    };

    publicHost = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "vi.${config.host.network.publicDomain}";
      description = "Public hostname used for Vikunja.";
    };

    metrics.port = lib.mkOption {
      type = lib.types.port;
      default = 9345;
      readOnly = true;
      internal = true;
      description = "LAN-visible Vikunja Prometheus endpoint port.";
    };

    backups.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to back up Vikunja files and its SQLite database.";
    };
  };
}
