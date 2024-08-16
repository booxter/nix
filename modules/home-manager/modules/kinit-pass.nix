{ pkgs, ... }: pkgs.writeShellScriptBin "kinit-pass" ''
  # TODO: use nix package for kinit?
  ${pkgs.pass}/bin/pass rh/ipa | kinit --password-file=STDIN
  ''
