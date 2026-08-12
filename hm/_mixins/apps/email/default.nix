{ osConfig, ... }:
let
  appsCfg = osConfig.host.userEnvironment.features.apps;
in
{
  imports = [
    ./gmailctl.nix
    ./thunderbird.nix
  ];

  host.hm = {
    gmailctl = {
      enable = appsCfg.enable && appsCfg.email.enable && appsCfg.email.gmailctl.enable;
      warmer.enable = appsCfg.enable && appsCfg.email.enable && appsCfg.email.gmailctl.enable;
    };

    thunderbird.enable = appsCfg.enable && appsCfg.email.enable && appsCfg.email.thunderbird.enable;
  };
}
