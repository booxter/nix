{ pkgs }:
let
  appSpec = import ../app-spec.nix;
  packageUpdateTools = import ./package.nix { inherit pkgs; };
in
{
  packages = {
    update-packages = packageUpdateTools;
    update-oci-images = packageUpdateTools;
  };
  appSpecs = {
    update-packages = appSpec "${packageUpdateTools}/bin/update-packages" "Update selected fetched packages and write a changelog-linked PR summary.";
    update-oci-images = appSpec "${packageUpdateTools}/bin/update-oci-images" "Update selected OCI image tags and write a changelog-linked PR summary.";
  };
}
