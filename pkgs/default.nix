# You can build them using 'nix build .#example'
pkgs:
{
  # private
  clean-uri-handlers = pkgs.callPackage ./clean-uri-handlers { };
  spot = pkgs.callPackage ./spot { };
}
