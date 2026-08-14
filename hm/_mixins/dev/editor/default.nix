{
  config,
  lib,
  ...
}:
lib.mkIf (config.host.hm.userEnvironment.preset != null) {
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
  };
}
