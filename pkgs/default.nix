# You can build them using 'nix build .#example'
pkgs: {
  # private
  spot = pkgs.callPackage ./spot { };

  # https://github.com/NixOS/nixpkgs/pull/432971
  air-sdk = pkgs.callPackage ./air-sdk { };

  # to upstream?
  jinjanator = pkgs.callPackage ./jinjanator { };
}
