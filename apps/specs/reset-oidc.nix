{
  facts,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit facts outputs pkgs; }).packages.reset-oidc;
  description = "Send a Kanidm OIDC credential reset email through pki.";
}
