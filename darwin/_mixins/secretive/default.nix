{
  config,
  lib,
  pkgs,
  ...
}:
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
  };
}
