{ pkgs, ... }: pkgs.writeShellScriptBin "kinit-pass" ''
  ${pkgs.pass}/bin/pass rh/ipa | ${pkgs.heimdal}/bin/kinit --password-file=STDIN
  ''
