{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.issue-internal-service-cert;
  description = "Issue internal PKI certs for internal HTTPS services and store them in host sops secrets.";
}
