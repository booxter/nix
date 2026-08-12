{ lib }:
path:
let
  key = lib.removeSuffix "\n" (builtins.readFile path);
in
assert lib.assertMsg (key != "") "public key ${toString path} must not be empty";
key
