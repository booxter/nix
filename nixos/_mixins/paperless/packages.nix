{ pkgs }:
{
  bootstrap = pkgs.callPackage ./pkgs/paperless-bootstrap { };
  gptConfigure = pkgs.callPackage ./pkgs/paperless-gpt-configure { };
  prometheusExporter = pkgs.callPackage ./pkgs/prometheus-paperless-exporter { };
}
