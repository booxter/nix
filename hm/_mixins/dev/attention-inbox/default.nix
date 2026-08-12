{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = osConfig.host.userEnvironment.features.dev;
  attentionInbox = pkgs.callPackage ./pkgs { };
in
lib.mkIf (cfg.enable && cfg.attentionInbox.enable) {
  home.packages = [ attentionInbox ];
}
