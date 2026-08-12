{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  cfg = config.host.hm.firefox;
in
{
  options.host.hm.firefox.passkeys.enable = lib.mkOption {
    type = lib.types.bool;
    default = isDarwin && osConfig.host.hardware.hasTouchId;
    defaultText = lib.literalExpression "osConfig.host.isDarwin && osConfig.host.hardware.hasTouchId";
    description = "Whether to use the signed upstream Firefox bundle for Touch ID-backed passkeys.";
  };

  config = lib.mkIf (cfg.enable && cfg.passkeys.enable) {
    assertions = [
      {
        assertion = isDarwin;
        message = "host.hm.firefox.passkeys is only supported on Darwin";
      }
    ];

    # Home Manager's wrapper replaces the executable inside Mozilla's signed
    # app bundle and breaks the entitlement macOS requires for Touch ID-backed
    # passkeys. Install the upstream bundle separately on Touch ID Macs.
    programs.firefox.package = null;

    home.activation.firefoxLaunchdEnvironment = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Finder/Dock-launched GUI apps inherit the user launchd environment,
      # not Home Manager's shell session variables.
      /bin/launchctl setenv MOZ_LEGACY_PROFILES 1
    '';

    home.packages = [ pkgs.firefox-bin-unwrapped ];
  };
}
