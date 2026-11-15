{ config, lib }:
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
  libraries = map compileLibrary (builtins.attrValues config.host.jellyfin.libraries);
  localizedNames = {
    Family = "Семейное";
    Movies = "Фильмы";
    Shows = "Сериалы";
    Docu = "Документальное";
    Attic = "Чердак";
  };
in
{
  inherit libraries localizedNames;
  localizedLibraries = map (
    library:
    library
    // {
      sourceName = library.name;
      name = localizedNames.${library.name};
    }
  ) (builtins.filter (library: builtins.hasAttr library.name localizedNames) libraries);
  requiredPlugins = lib.unique (lib.concatMap (library: library.requiredPlugins) libraries);
}
