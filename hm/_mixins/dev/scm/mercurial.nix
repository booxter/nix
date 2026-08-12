{
  config,
  lib,
  osConfig,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  inherit (config.host.hm) email fullName;
in
lib.mkIf (devCfg.enable && devCfg.scm.enable) {
  programs.mercurial = {
    enable = true;
    userName = fullName;
    userEmail = email;
    extraConfig.extensions.rebase = "";
  };
}
