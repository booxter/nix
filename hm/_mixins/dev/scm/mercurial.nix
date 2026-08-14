{
  config,
  lib,
  osConfig,
  ...
}:
let
  inherit (config.host.hm) email fullName;
in
lib.mkIf osConfig.host.userEnvironment.roles.developer.enable {
  programs.mercurial = {
    enable = true;
    userName = fullName;
    userEmail = email;
    extraConfig.extensions.rebase = "";
  };
}
