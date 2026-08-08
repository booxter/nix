pkgs: {
  paperless-bootstrap = pkgs.callPackage ./paperless-bootstrap { };
  paperless-gpt-configure = pkgs.callPackage ./paperless-gpt-configure { };
  prometheus-paperless-exporter = pkgs.callPackage ./prometheus-paperless-exporter { };
}
