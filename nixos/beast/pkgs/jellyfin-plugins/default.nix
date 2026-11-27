{ pkgs }:
let
  buildPlugin = pkgs.callPackage ./build-plugin.nix { };
  names = [
    "language-tags"
    "letterboxd"
    "lrclib"
    "meilisearch"
    "polyglot"
    "porndb"
    "tvdb"
    "webhook"
  ];
in
pkgs.lib.genAttrs names (
  name: pkgs.callPackage (./. + "/${name}/package.nix") { inherit buildPlugin; }
)
