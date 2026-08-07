{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.yubi.smartCard;
in
{
  options.programs.yubi.smartCard = {
    enable = lib.mkEnableOption "macOS SmartCardServices defaults for YubiKey PIV login";
    sshSudoPassword.enable = lib.mkEnableOption "password-only sudo authentication for interactive SSH sessions";
  };

  config = lib.mkIf cfg.enable {
    system.defaults.CustomSystemPreferences."/Library/Preferences/com.apple.security.smartcard" = {
      UserPairing = true;
      allowUnmappedUsers = 1;
      checkCertificateTrust = 0;
      enforceSmartCard = false;
    };

    environment.etc."pam.d/sudo_ssh_password" = lib.mkIf cfg.sshSudoPassword.enable {
      text = ''
        # sudo_ssh_password: auth account password session
        auth       required       pam_opendirectory.so
        account    required       pam_permit.so
        password   required       pam_deny.so
        session    required       pam_permit.so
      '';
    };

    security.sudo.extraConfig = lib.mkIf cfg.sshSudoPassword.enable (
      lib.mkAfter ''
        Defaults    pam_askpass_service=sudo_ssh_password
      ''
    );
  };
}
