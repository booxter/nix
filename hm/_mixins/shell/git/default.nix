{
  lib,
  osConfig,
  pkgs,
  ...
}:
lib.mkIf osConfig.host.userEnvironment.features.shell.enable {
  programs.git = {
    enable = true;
    package = pkgs.gitFull;
  };
}
