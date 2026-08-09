{ pkgs, ... }:
{
  package = (import ../package-updates { inherit pkgs; }).packages.update-packages;
  description = "Update selected fetched packages and write a changelog-linked PR summary.";
}
