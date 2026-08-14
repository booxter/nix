{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  userHome = config.users.users.${username}.home;
  credentials = config.host.ssh.credentials;
  useSecretive = credentials.backend == "secretive";
in
{
  options.host.ssh.credentials.secretive.publicKey = lib.mkOption {
    type = lib.types.nullOr lib.types.nonEmptyStr;
    default = null;
    description = "Public signing key managed by Secretive.";
  };

  config = lib.mkIf useSecretive {
    assertions = [
      {
        assertion = credentials.secretive.publicKey != null;
        message = "Secretive SSH credentials require host.ssh.credentials.secretive.publicKey.";
      }
    ];

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
      home.file.".ssh/secretive.pub".text = credentials.secretive.publicKey + "\n";
      programs.git.settings.user.signingKey = "${userHome}/.ssh/secretive.pub";
    };
  };
}
