{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  libraries = builtins.attrValues model.libraries;
  sources = map (library: library.source) libraries;
  displayNames = map (library: library.displayName) libraries;
in
{
  config.assertions = lib.optionals cfg.enable (
    [
      {
        assertion = cfg.publicHostName != null;
        message = "host.audiobookshelf.publicHostName must be set";
      }
      {
        assertion = model.ssoApplication != null;
        message = "host.audiobookshelf.sso.application must select a realm SSO application";
      }
      {
        assertion = cfg.libraries != { };
        message = "host.audiobookshelf.libraries must select at least one media library";
      }
      {
        assertion = builtins.hasAttr cfg.user config.host.accounts.users;
        message = "host.audiobookshelf.user must select a registered host account";
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
