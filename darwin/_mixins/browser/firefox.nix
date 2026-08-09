{
  config,
  lib,
  ...
}:
{
  config.launchd.user.envVariables =
    lib.mkIf (config.host.hardware.hasTouchId && config.host.userProfile == "personal")
      {
        # Finder/Dock-launched GUI apps inherit launchd's environment, not the
        # shell's. Signed, unwrapped Firefox needs this to keep using the legacy
        # Home Manager-managed profile path on macOS.
        MOZ_LEGACY_PROFILES = "1";
      };
}
