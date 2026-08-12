{ config, lib }:
let
  cfg = config.host.ebookConverter;
  mediaModel = import ../media-libraries/model.nix { inherit config lib; };
in
{
  inherit cfg;
  library = if cfg.library == null then null else mediaModel.resolved.${cfg.library} or null;
  metricsDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "/var/lib/prometheus-node-exporter-textfile/ebook-converter.prom";
}
