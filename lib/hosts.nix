{ lib }:
let
  discover =
    directory:
    lib.mapAttrs (name: _: directory + "/${name}") (
      lib.filterAttrs (
        name: type:
        type == "directory"
        && !lib.hasPrefix "_" name
        && builtins.pathExists (directory + "/${name}/default.nix")
      ) (builtins.readDir directory)
    );
  darwin = discover ../darwin;
  nixos = discover ../nixos;
  names = builtins.attrNames darwin ++ builtins.attrNames nixos;
in
assert lib.assertMsg (
  builtins.length names == builtins.length (lib.unique names)
) "host names must be unique across NixOS and Darwin";
{
  inherit darwin nixos;
}
