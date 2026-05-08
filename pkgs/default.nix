# You can build them using 'nix build .#example'
pkgs: {
  # private
  my-page = pkgs.callPackage ./page { };

  # https://github.com/NixOS/nixpkgs/pull/432971
  air-sdk = pkgs.callPackage ./air-sdk { };

  # to upstream?
  jinjanator = pkgs.callPackage ./jinjanator { };

  ismc = pkgs.callPackage ./ismc { };

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  aurral = pkgs.callPackage ./aurral { };

  transmission-tracker-prioritizer = pkgs.callPackage ./transmission-tracker-prioritizer { };
}
