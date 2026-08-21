{ lib, ... }:
let
  endpointType = lib.types.submodule {
    options = {
      jobName = lib.mkOption { type = lib.types.nonEmptyStr; };
      path = lib.mkOption { type = lib.types.str; };
      interval = lib.mkOption { type = with lib.types; nullOr str; };
      metricRelabelConfigs = lib.mkOption { type = with lib.types; listOf attrs; };
      target = lib.mkOption { type = lib.types.nonEmptyStr; };
      labels = lib.mkOption { type = with lib.types; attrsOf str; };
    };
  };
in
{
  options.host.observability.inventory = {
    endpoints = lib.mkOption {
      type = lib.types.attrsOf endpointType;
      default = { };
      internal = true;
    };

    blackbox = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            exporter = lib.mkOption { type = nonEmptyStr; };
            scheme = lib.mkOption {
              type = enum [
                "http"
                "https"
              ];
            };
            source = lib.mkOption { type = nonEmptyStr; };
          };
        });
      default = null;
      internal = true;
    };
  };
}
