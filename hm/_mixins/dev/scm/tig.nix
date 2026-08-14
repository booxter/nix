{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf (config.host.hm.userEnvironment.preset != null) {
  home.packages = [ pkgs.tig ];
  home.file.".tigrc".source = "${pkgs.tig.src}/contrib/vim.tigrc";
}
