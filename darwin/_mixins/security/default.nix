{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  userHome = config.users.users.${username}.home;
  smartCard = config.host.security.smartCard;
  sudo = config.host.security.sudo;
  useSecretive = config.host.security.ssh.credentials.backend == "secretive";
  secretivePublicKey = facts.public-keys.users.${hostname + "-secretive"};
in
{
  options.host.security = {
    smartCard.enable = lib.mkEnableOption "macOS SmartCardServices authentication";

    sudo = {
      sshPasswordAuth.enable = lib.mkOption {
        type = lib.types.bool;
        default = smartCard.enable;
        description = "Whether interactive SSH sessions use password-only sudo authentication.";
      };

      touchId.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.host.hardware.hasTouchId;
        description = "Whether local sudo authentication uses Touch ID.";
      };
    };
  };

  config = lib.mkMerge [
    {
      security.pam.services.sudo_local.touchIdAuth = lib.mkDefault sudo.touchId.enable;
      security.pam.services.sudo_local.reattach = lib.mkDefault sudo.touchId.enable;

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
    (lib.mkIf sudo.sshPasswordAuth.enable {
      environment.etc."pam.d/sudo_ssh_password".text = ''
        # sudo_ssh_password: auth account password session
        auth       required       pam_opendirectory.so
        account    required       pam_permit.so
        password   required       pam_deny.so
        session    required       pam_permit.so
      '';

      security.sudo.extraConfig = lib.mkAfter ''
        Defaults    pam_askpass_service=sudo_ssh_password
      '';
    })
    (lib.mkIf useSecretive {
      # Secretive expects its app in /Applications, not the user's Applications
      # directory, for its SSH agent integration.
      system.activationScripts.applications.text = lib.mkAfter ''
        install -o root -g wheel -m0555 -d "/Applications/Secretive.app"

        rsyncFlags=(
          --checksum
          --copy-unsafe-links
          --archive
          --delete
          --chmod=-w
          --no-group
          --no-owner
        )

        ${lib.getExe pkgs.rsync} "''${rsyncFlags[@]}" \
          ${pkgs.secretive}/Applications/Secretive.app/ /Applications/Secretive.app
      '';

      home-manager.users.${username} = {
        home.file.".ssh/secretive.pub".text = secretivePublicKey + "\n";
        programs.git.settings.user.signingKey = "${userHome}/.ssh/secretive.pub";
      };
    })
  ];
}
