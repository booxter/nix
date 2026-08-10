{ lib }:
facts:
let
  libraries = facts.libraries;
  unique = values: builtins.length values == builtins.length (lib.unique values);
in
[
  {
    assertion = unique (map (library: library.name) libraries);
    message = "media library names must be unique";
  }
  {
    assertion = unique (map (library: library.path) libraries);
    message = "media library paths must be unique";
  }
  {
    assertion = lib.all (
      library:
      builtins.elem library.kind [
        "movies"
        "series"
        "music"
      ]
    ) libraries;
    message = "media library kind must be movies, series, or music";
  }
  {
    assertion = lib.all (
      library:
      builtins.elem library.audience [
        "general"
        "adult"
      ]
    ) libraries;
    message = "media library audience must be general or adult";
  }
  {
    assertion = lib.all (
      library:
      builtins.elem library.metadataPolicy [
        "default"
        "tmdb-first"
      ]
    ) libraries;
    message = "media library metadata policy must be default or tmdb-first";
  }
  {
    assertion = lib.all (
      library: library.metadataPolicy != "tmdb-first" || library.kind == "movies"
    ) libraries;
    message = "tmdb-first metadata policy is only defined for movie libraries";
  }
]
