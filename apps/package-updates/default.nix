{ pkgs }:
let
  packageUpdateTools = import ./package.nix { inherit pkgs; };
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
in
{
  packages = {
    update-packages = packageUpdateTools;
    update-oci-images = packageUpdateTools;
  };
  apps = {
    update-packages = mkApp "${packageUpdateTools}/bin/update-packages" "Update selected fetched packages and write a changelog-linked PR summary.";
    update-oci-images = mkApp "${packageUpdateTools}/bin/update-oci-images" "Update selected OCI image tags and write a changelog-linked PR summary.";
  };
}
