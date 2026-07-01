{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.host.browser.firefox.touchIdPasskeys;
in
{
  options.host.browser.firefox.touchIdPasskeys.enable = lib.mkEnableOption (
    "Firefox Touch ID/passkey support through the signed upstream app"
  );

  config = lib.mkIf cfg.enable {
    home-manager.users.${username} = {
      programs.firefox = {
        # Keep Home Manager managing Firefox profiles, settings, extensions,
        # and policies, but do not let its Firefox module install the browser
        # on Darwin. Even setting this to firefox-bin-unwrapped would still go
        # through the module's wrapper path, replacing Mozilla's signed
        # Contents/MacOS/firefox with a shell script. That breaks the upstream
        # signature and the entitlement macOS checks before allowing Touch ID
        # fingerprint use for passkeys.
        package = null;
      };

      # Install Mozilla's signed app bundle unchanged. Home Manager's Darwin
      # app copier can then expose it under ~/Applications/Home Manager Apps
      # without invoking the Firefox wrapper that strips the passkey entitlement.
      home.packages = [
        pkgs.firefox-bin-unwrapped
      ];
    };

    launchd.user.envVariables = {
      # Finder/Dock-launched GUI apps inherit launchd's environment, not the
      # shell's. The signed unwrapped Firefox no longer gets Nix's wrapper env,
      # so provide the one variable needed to keep using the legacy
      # Home Manager-managed profile path on macOS.
      MOZ_LEGACY_PROFILES = "1";
    };
  };
}
