{ lib, pkgs }:
let
  root = ../..;
  source = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.fileFilter (file: file.hasExt "py" || file.name == "ruff.toml") root;
  };
in
pkgs.runCommand "python-quality"
  {
    nativeBuildInputs = [ pkgs.ruff ];
  }
  ''
    cd ${source}
    ruff format --check --no-cache --config ./ruff.toml .
    ruff check --no-cache --config ./ruff.toml .
    touch "$out"
  ''
