{
  config,
  lib,
  ...
}:
let
  smartCard = config.host.security.smartCard;
in
{
  options.host.security.smartCard.enable =
    lib.mkEnableOption "macOS SmartCardServices authentication";

  config = lib.mkMerge [
    {
      security.pam.services.sudo_local.touchIdAuth = lib.mkDefault config.host.hardware.hasTouchId;
      security.pam.services.sudo_local.reattach = lib.mkDefault config.host.hardware.hasTouchId;

      security.sudo.extraConfig = ''
        Defaults    timestamp_timeout=30
      '';
    }
    (lib.mkIf smartCard.enable {
      system.defaults.CustomSystemPreferences."/Library/Preferences/com.apple.security.smartcard" = {
        UserPairing = true;
        allowUnmappedUsers = 1;
        checkCertificateTrust = 0;
        enforceSmartCard = false;
      };
    })
  ];
}
