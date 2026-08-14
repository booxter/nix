{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.wireshark;
  graphical = pkgs.stdenv.hostPlatform.isDarwin || osConfig.host.desktop.enable;
in
{
  options.host.hm.wireshark.enable = lib.mkEnableOption "Wireshark network protocol analyzer";

  config = {
    assertions = [
      {
        assertion = !cfg.enable || graphical;
        message = "host.hm.wireshark requires a managed graphical environment.";
      }
    ];

    home.packages = lib.optional cfg.enable pkgs.wireshark;
  };
}
