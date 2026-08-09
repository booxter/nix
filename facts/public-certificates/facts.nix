{
  lib,
  root ? ./files,
}:
(import ../_lib/namespaced-files.nix { inherit lib; }) {
  inherit root;
  description = "public certificate";
  extension = ".crt";
  load =
    path:
    assert lib.assertMsg (
      builtins.readFile path != ""
    ) "public certificate ${toString path} must not be empty";
    path;
}
