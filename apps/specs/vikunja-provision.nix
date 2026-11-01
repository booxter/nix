{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../packages.nix { inherit pkgs; }).vikunja-provision.override {
    declarations = import ../vikunja-provision/declarations.nix {
      inherit fleetInventory;
      inherit (pkgs) lib;
      inherit (outputs) nixosConfigurations;
    };
  };
  description = "Reconcile Vikunja bots, project access, and MCP tokens.";
}
