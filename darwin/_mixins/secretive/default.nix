{ lib, pkgs, ... }:
{
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
}
