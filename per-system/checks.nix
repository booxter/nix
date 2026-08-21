{
  appSet,
  inputs,
  pkgs,
  ...
}:
appSet.packages // import ../tests { inherit inputs pkgs; }
