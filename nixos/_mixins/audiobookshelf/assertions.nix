{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  libraries = builtins.attrValues model.libraries;
in
{
  config.assertions = lib.optionals (cfg != null) (
    [
      {
        assertion = model.ssoApplication != null;
        message = "Audiobookshelf requires its realm SSO application";
      }
    ]
    ++ map (library: {
      assertion =
        library.media != null
        && builtins.elem library.media.contentType [
          "audiobooks"
          "ebooks"
        ];
      message = "host.audiobookshelf.libraries.${library.source} must select an audiobook or ebook library";
    }) libraries
  );
}
