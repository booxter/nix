# You can build them using 'nix build .#example'
pkgs: {
  # private
  spot = pkgs.callPackage ./spot { };

  # to upstream?
  air-sdk = pkgs.callPackage ./air-sdk { };
  jinjanator = pkgs.callPackage ./jinjanator { };
}
