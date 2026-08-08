{ pkgs, ... }:
{
  _module.args.orgPkgs = import ./pkgs pkgs;

  imports = [
    ./backup.nix
    ./paperless.nix
  ];
}
