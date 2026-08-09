{ lib, ... }:
{
  options.host.observability.grafana = {
    dashboardManifest = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Normalized fleet facts consumed by the Grafana dashboard generator.";
    };
    dashboardPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Generated Grafana dashboard directory.";
    };
  };
}
