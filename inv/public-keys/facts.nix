{
  lib,
  root ? ../../public-keys,
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
        name: type: type != "regular" || !lib.hasSuffix ".pub" name || name == ".pub"
      ) entries;
      loadKey =
        name: _:
        let
          key = lib.removeSuffix "\n" (builtins.readFile (directory + "/${name}"));
        in
        assert lib.assertMsg (key != "") "public key ${namespace}/${name} must not be empty";
        lib.nameValuePair (lib.removeSuffix ".pub" name) key;
    in
    assert lib.assertMsg (entries != { }) "public key namespace ${namespace} must not be empty";
    assert lib.assertMsg (invalidEntries == { }) (
      "public key namespace ${namespace} must contain only <name>.pub files; invalid entries: "
      + lib.concatStringsSep ", " (builtins.attrNames invalidEntries)
    );
    lib.mapAttrs' loadKey entries;
in
assert lib.assertMsg (invalidRootEntries == { }) (
  "public-keys must contain only namespace directories; invalid entries: "
  + lib.concatStringsSep ", " (builtins.attrNames invalidRootEntries)
);
lib.mapAttrs loadNamespace rootEntries
