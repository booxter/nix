{
  config,
  lib,
  ...
}:
lib.mkIf config.host.hm.env.roles.developer {
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
  };
}
