{ config, lib }:
let
  cfg = config.host.shelfmark;
  mediaModel = import ../../media-libraries/model.nix { inherit config lib; };
in
{
  inherit cfg;
  library = if cfg == null then null else mediaModel.resolved.${cfg.libraries.ebooks} or null;
  stateDir = "/var/lib/ebook-converter";
  user = "ebook-converter";
  group = "media";
  metricsDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "/var/lib/prometheus-node-exporter-textfile/ebook-converter.prom";
}
