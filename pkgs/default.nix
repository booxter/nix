# You can build them using 'nix build .#example'
pkgs:
{
  # private
  aws-automation = pkgs.callPackage ./aws-automation { };
  clean-uri-handlers = pkgs.callPackage ./clean-uri-handlers { };
  kinit-pass = pkgs.callPackage ./kinit-pass { };
  meetings = pkgs.callPackage ./meetings { };
  spot = pkgs.callPackage ./spot { };
  vpn = pkgs.callPackage ./vpn { };

  # to upstream
  homerow = pkgs.callPackage ./homerow { };
}
