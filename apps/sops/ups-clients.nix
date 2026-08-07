{
  hostInventory,
  lib,
}:
let
  credentialMode = spec: hostInventory.realms.${spec.realm}.services.ups.credentialMode;
  serverUsesSops = server: credentialMode hostInventory.nixosHosts.${server} == "sops";

  includeClient =
    spec: spec ? upsHost && credentialMode spec == "sops" && serverUsesSops spec.upsHost;

  nixosEntries = map (spec: {
    server = spec.upsHost;
    client = spec.name;
  }) (builtins.filter includeClient hostInventory.nixosHostSpecs);

  darwinEntries = map (spec: {
    server = spec.upsHost;
    client = spec.name;
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
