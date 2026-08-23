{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package =
    (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.issue-internal-service-cert;
  description = "Issue internal PKI certs for internal HTTPS services and store them in host sops secrets.";
}
