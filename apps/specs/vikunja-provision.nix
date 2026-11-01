{ pkgs, ... }:
{
  package = (import ../packages.nix { inherit pkgs; }).vikunja-provision;
  description = "Reconcile Vikunja bots, project access, and MCP tokens.";
}
