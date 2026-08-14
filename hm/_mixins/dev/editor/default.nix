{
  config,
  lib,
  ...
}:
lib.mkIf (config.host.hm.env.preset != null) {
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
  };
}
