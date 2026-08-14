{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.wireshark;
in
{
  options.host.hm.wireshark.enable = lib.mkEnableOption "Wireshark network protocol analyzer";

  config = {
    assertions = [
      {
        assertion = !cfg.enable || osConfig.host.desktop.enable;
        message = "host.hm.wireshark requires a managed graphical environment.";
      }
    ];

    home.packages = lib.optional cfg.enable pkgs.wireshark;
  };
}
