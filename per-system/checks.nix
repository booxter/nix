{
  appSet,
  pkgs,
  ...
}:
appSet.packages // import ../tests { inherit pkgs; }
