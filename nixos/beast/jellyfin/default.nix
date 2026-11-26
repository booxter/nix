{
  config,
  inputs,
  pkgs,
  ...
}:
let
  # Keep the deployed server, web client, transcoder and reconciler together.
  jellyfinPkgs = import inputs.nixpkgs-jellyfin {
    inherit (config.nixpkgs) config overlays;
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in
{
  imports = [
    ./language-tags-refresh.nix
    ./libraries.nix
    ./localization.nix
    ./plugins.nix
    ./server.nix
    ./users.nix
  ];

  services.jellyfin.package = jellyfinPkgs.jellyfin;
  services.jellarr.package = jellyfinPkgs.callPackage ../../_mixins/jellyfin/packages/jellarr {
    src = inputs.jellarr;
  };

  host.jellyfin = {
    media = {
      provider = "beast";
      resource = "media";
    };
    libraries = {
      movies = {
        name = "Movies";
        path = "movies";
        kind = "movies";
      };
      shows = {
        name = "Shows";
        path = "shows";
        kind = "series";
      };
      family = {
        name = "Family";
        path = "family";
        kind = "movies";
      };
      anime = {
        name = "Anime";
        path = "anime";
        kind = "movies";
      };
      docu = {
        name = "Docu";
        path = "docu";
        kind = "movies";
      };
      stand-up = {
        name = "Stand-up";
        path = "standup";
        kind = "movies";
      };
      attic = {
        name = "Attic";
        path = "attic";
        kind = "movies";
        audience = "adult";
        metadataPolicy = "tmdb-first";
      };
      fruit = {
        name = "Fruit";
        path = "xxx";
        kind = "movies";
        audience = "adult";
        metadataPolicy = "tmdb-first";
      };
      fruitsies = {
        name = "Fruitsies";
        path = "fruitsies";
        kind = "series";
        audience = "adult";
      };
      music = {
        name = "Music";
        path = "music";
        kind = "music";
      };
    };
    backups.stagingDirectory = "/volume2/backups/staging/jellyfin";
  };
}
