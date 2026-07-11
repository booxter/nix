{
  lib,
  hostInventory ? import ./inventory.nix { inherit lib; },
}:
let
  serverIsWork = server: (hostInventory.nixosHostSpecsByName.${server}.isWork or false);

  includeClient = spec: spec ? upsHost && !(spec.isWork or false) && !(serverIsWork spec.upsHost);

  nixosEntries = map (spec: {
    server = spec.upsHost;
    client = hostInventory.toNixosConfigName spec;
  }) (builtins.filter includeClient hostInventory.nixosHostSpecs);

  darwinEntries = map (spec: {
    server = spec.upsHost;
    client = spec.hostname;
  }) (builtins.attrValues (lib.filterAttrs (_: includeClient) hostInventory.darwinHosts));

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
