{
  config,
  lib,
  ...
}:
{
  config = {
    security.pam.services.sudo_local.touchIdAuth = lib.mkDefault config.host.hardware.hasTouchId;
    security.pam.services.sudo_local.reattach = lib.mkDefault config.host.hardware.hasTouchId;

    security.sudo.extraConfig = ''
      Defaults    timestamp_timeout=30
    '';

    system.defaults.CustomSystemPreferences."/Library/Preferences/com.apple.security.smartcard" = {
      UserPairing = false;
    };
  };
}
