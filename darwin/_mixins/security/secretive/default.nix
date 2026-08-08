{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  userHome = config.users.users.${username}.home;
  sshDirectory = config.host.ssh.userDirectory;
  sshIdentity = hostInventory.ssh.userIdentities.mairSecretive;
  secretivePublicKeyPath = "${sshDirectory}/${sshIdentity.fileName}";
  secretivePublicKeyFile = lib.removePrefix "${userHome}/" secretivePublicKeyPath;
in
{
  options.host.secretive.enable = lib.mkEnableOption "Secretive system application installation";

  config = lib.mkIf config.host.secretive.enable {
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
      home.file.${secretivePublicKeyFile}.text = "${sshIdentity.publicKey}\n";
      programs.git.settings.user.signingKey = secretivePublicKeyPath;
    };
  };
}
