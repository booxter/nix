{ pkgs }:
let
  packageUpdateTools = import ./package.nix { inherit pkgs; };
in
{
  packages = {
    update-packages = packageUpdateTools;
    update-oci-images = packageUpdateTools;
  };
}
