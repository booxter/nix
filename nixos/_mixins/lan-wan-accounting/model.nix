{ config }:
let
  cfg = config.host.observability.lanWan;
in
{
  inherit cfg;
  tableName = "observability_lan_wan";
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  egressOverrideEnabled = cfg.wanEgressOverride != null;
}
