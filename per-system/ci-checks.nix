args:
let
  catalog = import ./checks/catalog.nix args;
in
{
  batch = builtins.attrNames catalog.batchChecks;
  nixosTests = builtins.attrNames catalog.nixosTests;
}
