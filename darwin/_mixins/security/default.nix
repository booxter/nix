{
  config,
  lib,
  ...
}:
let
  homeRealm = config.host.realm == "home";
in
{
  imports = [ ./sudo.nix ];

  config = {
    security.pam.services.sudo_local.touchIdAuth = lib.mkDefault config.host.hardware.hasTouchId;
    security.pam.services.sudo_local.reattach = lib.mkDefault config.host.hardware.hasTouchId;

    system.defaults.CustomSystemPreferences."/Library/Preferences/com.apple.security.smartcard" =
      lib.optionalAttrs homeRealm
        {
          UserPairing = false;
        };

    # Home hosts use their SSH host keys; keep the retired generated identity absent.
    system.activationScripts.postActivation.text = lib.mkIf homeRealm (
      lib.mkAfter ''
        /bin/rm -f /var/lib/sops-nix/key.txt
      ''
    );
  };
}
