{
  lib,
  osConfig,
  ...
}:
let
  cfg = osConfig.host.userEnvironment.features.dev;
in
lib.mkIf (cfg.enable && cfg.editor.enable) {
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
  };
}
