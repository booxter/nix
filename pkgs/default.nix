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

  adaptive-upload-controller = pkgs.callPackage ./adaptive-upload-controller { };

  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  nightly-speedtest-probe = pkgs.callPackage ./nightly-speedtest-probe { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner { };

  transmission-tracker-prioritizer = pkgs.callPackage ./transmission-tracker-prioritizer { };
}
