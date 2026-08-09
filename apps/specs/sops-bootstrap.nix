{ facts, pkgs, ... }:
{
  package = (import ../sops { inherit facts pkgs; }).packages.sops-tools;
  description = "Bootstrap host sops secrets and key recipients.";
}
