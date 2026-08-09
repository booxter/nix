{
  lib,
  root ? ./files,
}:
(import ../_lib/namespaced-files.nix { inherit lib; }) {
  inherit root;
  description = "public key";
  extension = ".pub";
  load =
    path:
    let
      key = lib.removeSuffix "\n" (builtins.readFile path);
    in
    assert lib.assertMsg (key != "") "public key ${toString path} must not be empty";
    key;
}
