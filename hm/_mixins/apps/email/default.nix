{ osConfig, ... }:
let
  appsCfg = osConfig.host.userEnvironment.features.apps;
in
{
  imports = [
    ./gmailctl.nix
    ./thunderbird.nix
  ];

  host.hm.thunderbird.enable =
    appsCfg.enable && appsCfg.email.enable && appsCfg.email.thunderbird.enable;
}
