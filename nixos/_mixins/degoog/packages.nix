{ pkgs }:
let
  degoog = pkgs.callPackage ./pkgs/degoog { };
in
{
  inherit degoog;
  settings = pkgs.callPackage ./pkgs/degoog-settings {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  devinsideExtensions = pkgs.callPackage ./pkgs/degoog/devinside-extensions.nix { };
  georgvwtExtensions = pkgs.callPackage ./pkgs/degoog/georgvwt-extensions.nix { };
  officialExtensions = pkgs.callPackage ./pkgs/degoog/official-extensions.nix {
    degoogNodeModules = degoog.productionNodeModules;
  };
  stackexchangeEngine = pkgs.callPackage ./pkgs/degoog/stackexchange-engine.nix { };
  toolkitExtensions = pkgs.callPackage ./pkgs/degoog/toolkit-extensions.nix {
    degoogVersion = degoog.version;
  };
  trustedHeaderSettingsAuth = pkgs.callPackage ./pkgs/degoog-trusted-header-settings-auth { };
}
