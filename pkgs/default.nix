# You can build them using 'nix build .#example'
pkgs: {
  # private
  spot = pkgs.callPackage ./spot { };

  # to upstream?
  jinjanator = pkgs.callPackage ./jinjanator { };
}
