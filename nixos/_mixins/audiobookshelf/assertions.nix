{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  libraries = builtins.attrValues model.libraries;
  sources = map (library: library.source) libraries;
  displayNames = map (library: library.displayName) libraries;
in
{
  config.assertions = lib.optionals (cfg != null) (
    [
      {
        assertion = model.ssoApplication != null;
        message = "Audiobookshelf requires its realm SSO application";
      }
      {
        assertion = cfg.libraries != { };
        message = "host.audiobookshelf.libraries must select at least one media library";
      }
      {
        assertion = builtins.length sources == builtins.length (lib.unique sources);
        message = "host.audiobookshelf.libraries cannot select the same media library twice";
      }
      {
        assertion = builtins.length displayNames == builtins.length (lib.unique displayNames);
        message = "host.audiobookshelf.libraries display names must be unique";
      }
    ]
    ++ map (library: {
      assertion =
        library.media != null
        && builtins.elem library.media.contentType [
          "audiobooks"
          "ebooks"
        ];
      message = "host.audiobookshelf.libraries.${library.name}.source must select an audiobook or ebook library";
    }) libraries
  );
}
