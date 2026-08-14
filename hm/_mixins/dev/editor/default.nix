{
  lib,
  osConfig,
  ...
}:
lib.mkIf osConfig.host.userEnvironment.roles.developer.enable {
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
  };
}
