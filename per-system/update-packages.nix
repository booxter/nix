{
  lib,
  pkgs,
  plainPkgs,
  system,
  ...
}:
let
  sharedPackages = import ../pkgs plainPkgs;
in
lib.optionalAttrs (lib.hasSuffix "-darwin" system) {
  ismc = plainPkgs.callPackage ../darwin/_mixins/thermal-accounting/pkgs/ismc { };
}
// lib.optionalAttrs (lib.hasSuffix "-linux" system) {
  inherit (sharedPackages) aiosqlitepool firefox-devtools-mcp oomd;
  ebook-converter-cli = plainPkgs.callPackage ../nixos/_mixins/shelfmark/ebook-converter/cli {
    inherit (pkgs) nix-update-script;
  };
  houndarr = pkgs.houndarr;
  nico-cli = (import ../hm/_mixins/dev/nvidia/pkgs { pkgs = plainPkgs; }).nico-cli;
  paperless-llm-ocr =
    plainPkgs.paperless-ngx.python.pkgs.callPackage ../nixos/_mixins/paperless/pkgs/paperless-llm-ocr
      { };
  prometheus-paperless-exporter =
    plainPkgs.callPackage ../nixos/_mixins/paperless/pkgs/prometheus-paperless-exporter
      { };
}
