{
  fleetInventory,
  lib,
}:
let
  webIds = map (contribution: contribution.value.dashboard.id) (
    builtins.filter (
      contribution: contribution.value.dashboard != null
    ) fleetInventory.webServices.contributions
  );
  directIds = builtins.attrNames fleetInventory.dashboard;
  ids = webIds ++ directIds;
  idsById = builtins.groupBy (id: id) ids;
  duplicateIds = builtins.attrNames (
    lib.filterAttrs (_: values: builtins.length values != 1) idsById
  );
in
lib.optional (duplicateIds != [ ]) (
  "dashboard entry IDs must be unique across the fleet: " + lib.concatStringsSep ", " duplicateIds
)
