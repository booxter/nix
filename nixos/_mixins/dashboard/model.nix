{
  directEntries,
  lib,
  webEntries,
}:
let
  entries = webEntries ++ directEntries;
  byIdLists = builtins.groupBy (entry: entry.id) entries;
  duplicateIds = lib.filterAttrs (_: values: builtins.length values != 1) byIdLists;
  byId = lib.mapAttrs (_: values: builtins.head values) byIdLists;
  forScope =
    scope:
    map (
      entry:
      let
        selected =
          if scope == "public" then
            entry.endpoints.public
          else if entry.endpoints.public != null then
            entry.endpoints.public
          else
            entry.endpoints.internal;
      in
      entry // { endpoint = selected; }
    ) (builtins.filter (entry: scope != "public" || entry.endpoints.public != null) entries);
in
assert lib.assertMsg (duplicateIds == { }) (
  "dashboard entry IDs must be unique across the fleet: "
  + lib.concatStringsSep ", " (builtins.attrNames duplicateIds)
);
{
  inherit byId entries forScope;
  internal = forScope "internal";
  public = forScope "public";
}
