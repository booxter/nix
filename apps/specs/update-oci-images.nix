{ pkgs, ... }:
{
  package = (import ../package-updates { inherit pkgs; }).packages.update-oci-images;
  description = "Update selected OCI image tags and write a changelog-linked PR summary.";
}
