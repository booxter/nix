{
  appSet,
  pkgs,
  ...
}:
appSet.packages
// {
  patch-context = pkgs.patch-context;
}
// import ../tests { inherit pkgs; }
