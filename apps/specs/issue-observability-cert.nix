{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package =
    (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.issue-observability-cert;
  description = "Issue internal PKI certs for Prometheus mTLS scrape endpoints and store them in host sops secrets.";
}
