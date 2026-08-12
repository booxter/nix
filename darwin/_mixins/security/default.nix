{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  userHome = config.users.users.${username}.home;
  smartCard = config.host.security.smartCard;
  sudo = config.host.security.sudo;
  sshCredentials = config.host.security.ssh.credentials;
  useSecretive = sshCredentials.backend == "secretive";
in
{
  options.host.security = {
    smartCard.enable = lib.mkEnableOption "macOS SmartCardServices authentication";

    sudo.touchId.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.host.hardware.hasTouchId;
      description = "Whether local sudo authentication uses Touch ID.";
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
        home.file.".ssh/secretive.pub".text = sshCredentials.secretive.publicKey + "\n";
        programs.git.settings.user.signingKey = "${userHome}/.ssh/secretive.pub";
      };
    })
  ];
}
