{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.host.hm.env.roles.developer {
  home.packages = [ pkgs.tig ];
  home.file.".tigrc".source = "${pkgs.tig.src}/contrib/vim.tigrc";
}
