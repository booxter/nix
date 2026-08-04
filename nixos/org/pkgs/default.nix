pkgs:
let
  degoogPackage = pkgs.callPackage ./degoog { };
in
{
  degoog = degoogPackage;
  degoog-settings = pkgs.callPackage ./degoog-settings {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  degoog-devinside-extensions = pkgs.callPackage ./degoog/devinside-extensions.nix { };
  degoog-georgvwt-extensions = pkgs.callPackage ./degoog/georgvwt-extensions.nix { };
  degoog-official-extensions = pkgs.callPackage ./degoog/official-extensions.nix {
    degoogNodeModules = degoogPackage.productionNodeModules;
  };
  degoog-stackexchange-engine = pkgs.callPackage ./degoog/stackexchange-engine.nix { };
  degoog-toolkit-extensions = pkgs.callPackage ./degoog/toolkit-extensions.nix {
    degoogVersion = degoogPackage.version;
  };
  degoog-trusted-header-settings-auth = pkgs.callPackage ./degoog-trusted-header-settings-auth { };
  open-webui-tool-acl-reconcile = pkgs.callPackage ./open-webui-tool-acl-reconcile { };
  paperless-bootstrap = pkgs.callPackage ./paperless-bootstrap { };
  paperless-gpt-configure = pkgs.callPackage ./paperless-gpt-configure { };
  prometheus-paperless-exporter = pkgs.callPackage ./prometheus-paperless-exporter { };
  search-stack-probes = pkgs.callPackage ./search-stack-probes { };
  searchless-ngx = pkgs.callPackage ./searchless-ngx { };
  telegram-archive = pkgs.callPackage ./telegram-archive { };
  trilium-bootstrap = pkgs.callPackage ./trilium-bootstrap { };
}
