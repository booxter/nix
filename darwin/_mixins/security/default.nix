{
  config,
  lib,
  ...
}:
let
  smartCard = config.host.security.smartCard;
in
{
  options.host.security.smartCard = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
    description = "macOS SmartCardServices authentication policy.";
  };

  config = {
    security.pam.services.sudo_local.touchIdAuth = lib.mkDefault config.host.hardware.hasTouchId;
    security.pam.services.sudo_local.reattach = lib.mkDefault config.host.hardware.hasTouchId;

    security.sudo.extraConfig = ''
      Defaults    timestamp_timeout=30
    '';

    system.defaults.CustomSystemPreferences = lib.mkIf (smartCard != null) {
      "/Library/Preferences/com.apple.security.smartcard" = {
        UserPairing = true;
        allowUnmappedUsers = 1;
        checkCertificateTrust = 0;
        enforceSmartCard = false;
      };
    };
  };
}
