{ lib }:
{
  description,
  extension,
  load,
  root,
}:
let
  rootEntries = builtins.readDir root;
  invalidRootEntries = lib.filterAttrs (_: type: type != "directory") rootEntries;
  loadNamespace =
    namespace: _:
    let
      directory = root + "/${namespace}";
      entries = builtins.readDir directory;
      invalidEntries = lib.filterAttrs (
        name: type: type != "regular" || !lib.hasSuffix extension name || name == extension
      ) entries;
    in
    assert lib.assertMsg (entries != { }) "${description} namespace ${namespace} must not be empty";
    assert lib.assertMsg (invalidEntries == { }) (
      "${description} namespace ${namespace} must contain only <name>${extension} files; invalid entries: "
      + lib.concatStringsSep ", " (builtins.attrNames invalidEntries)
    );
    lib.mapAttrs' (
      name: _: lib.nameValuePair (lib.removeSuffix extension name) (load (directory + "/${name}"))
    ) entries;
in
assert lib.assertMsg (invalidRootEntries == { }) (
  "${description} root must contain only namespace directories; invalid entries: "
  + lib.concatStringsSep ", " (builtins.attrNames invalidRootEntries)
);
lib.mapAttrs loadNamespace rootEntries
