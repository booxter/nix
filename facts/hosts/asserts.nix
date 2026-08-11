{ lib }:
raw:
let
  names = builtins.attrNames raw.darwin ++ builtins.attrNames raw.nixos;
in
[
  {
    assertion = builtins.length names == builtins.length (lib.unique names);
    message = "host names must be unique";
  }
]
