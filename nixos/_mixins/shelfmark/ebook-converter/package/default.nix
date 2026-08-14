{ pkgs }:
let
  ebookConverterCli = pkgs.callPackage ./cli { };
in
pkgs.callPackage ./converter {
  atomicFileWrites = pkgs.atomic-file-writes;
  inherit ebookConverterCli;
}
