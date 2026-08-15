{
  config,
  lib,
  ...
}:
let
  inherit (config.host.hm) email fullName;
in
lib.mkIf config.host.hm.env.roles.developer {
  programs.mercurial = {
    enable = true;
    userName = fullName;
    userEmail = email;
    extraConfig.extensions.rebase = "";
  };
}
