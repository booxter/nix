pkgs: {
  paperless-gpt-configure = pkgs.callPackage ./paperless-gpt-configure { };
  prometheus-paperless-exporter = pkgs.callPackage ./prometheus-paperless-exporter { };
  searchless-ngx = pkgs.callPackage ./searchless-ngx { };
  telegram-archive = pkgs.callPackage ./telegram-archive { };
}
