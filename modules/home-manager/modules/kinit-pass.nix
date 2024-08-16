{ pkgs, ... }: pkgs.writeScriptBin "kinit-pass" ''
  {pkgs.pass}/bin/pass rh/ipa | kinit
  ''
