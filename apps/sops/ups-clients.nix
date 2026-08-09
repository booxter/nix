{
  hostInventory,
  lib,
}:
let
  credentialMode =
    host:
    hostInventory.realms.${hostInventory.hostSpecsByName.${host}.realm}.services.ups.credentialMode;
  relationships = lib.filterAttrs (
    client: server: credentialMode client == "sops" && credentialMode server == "sops"
  ) hostInventory.ups.clients;
  entries = lib.mapAttrsToList (client: server: { inherit client server; }) relationships;

  addEntry =
    acc: entry:
    acc
    // {
      ${entry.server} = (acc.${entry.server} or [ ]) ++ [ entry.client ];
    };
in
lib.mapAttrs (_: clients: lib.sort lib.lessThan clients) (builtins.foldl' addEntry { } entries)
