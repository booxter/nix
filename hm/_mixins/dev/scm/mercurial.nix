{
  config,
  lib,
  ...
}:
let
  inherit (config.host.hm) email fullName;
in
lib.mkIf (config.host.hm.userEnvironment.preset != null) {
  programs.mercurial = {
    enable = true;
    userName = fullName;
    userEmail = email;
    extraConfig.extensions.rebase = "";
  };
}
