{
  facts,
  lib,
}:
let
  profiles = import ./profiles.nix { inherit lib; };
  compileLibrary =
    library:
    let
      kind = profiles.kinds.${library.kind};
      audience = profiles.audiences.${library.audience};
    in
    library
    // {
      inherit (kind) collectionType;
      typeOptions = profiles.typeOptions library;
      requiredPlugins = lib.unique (kind.requiredPlugins ++ audience.requiredPlugins);
    };
  libraries = map compileLibrary facts.media-libraries.libraries;
in
{
  inherit libraries;
  requiredPlugins = lib.unique (lib.concatMap (library: library.requiredPlugins) libraries);
}
