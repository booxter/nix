{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.wireshark;
  netCfg = osConfig.host.userEnvironment.features.net;
in
{
  options.host.hm.wireshark.enable = lib.mkEnableOption "Wireshark network protocol analyzer";

  config = {
    assertions = [
      {
        assertion = !cfg.enable || netCfg.enable;
        message = "host.hm.wireshark requires network diagnostics.";
      }
      {
        assertion = !cfg.enable || osConfig.host.userEnvironment.roles.workstation.enable;
        message = "host.hm.wireshark requires a managed graphical environment.";
      }
    ];

    home.packages = lib.optional cfg.enable pkgs.wireshark;
  };
}
