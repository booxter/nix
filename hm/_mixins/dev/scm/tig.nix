{
  lib,
  osConfig,
  pkgs,
  ...
}:
lib.mkIf osConfig.host.userEnvironment.roles.developer.enable {
  home.packages = [ pkgs.tig ];
  home.file.".tigrc".source = "${pkgs.tig.src}/contrib/vim.tigrc";
}
