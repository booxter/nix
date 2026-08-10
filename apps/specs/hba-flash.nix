{
  facts,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit facts outputs pkgs; }).packages.hba-flash;
  description = "Preflight and flash the Broadcom/LSI HBA on beast using pinned Broadcom bundles by default.";
}
