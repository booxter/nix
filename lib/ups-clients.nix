{
  lib,
  hostInventory ? import ./inventory.nix { inherit lib; },
}:
let
  serverIsWork = server: (hostInventory.nixosHostSpecsByName.${server}.isWork or false);

  includeClient = spec: spec ? upsHost && !(spec.isWork or false) && !(serverIsWork spec.upsHost);

  nixosEntries = map (spec: {
    server = spec.upsHost;
    client = if spec.type == "vm" then spec.name else hostInventory.toNixosConfigName spec;
  }) (builtins.filter includeClient hostInventory.nixosHostSpecs);

  darwinEntries = lib.mapAttrsToList (_: spec: {
    server = spec.upsHost;
    client = spec.hostname;
  }) (lib.filterAttrs (_: includeClient) hostInventory.darwinHosts);

  addEntry =
    acc: entry:
    acc
    // {
      ${entry.server} = (acc.${entry.server} or [ ]) ++ [ entry.client ];
    };
in
lib.mapAttrs (_: clients: lib.sort lib.lessThan clients) (
  builtins.foldl' addEntry { } (nixosEntries ++ darwinEntries)
)
