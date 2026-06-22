{
  config,
  lib,
  ...
}:
let
  mkServarrApp = import ./mk-servarr-app.nix { inherit config lib; };
in
mkServarrApp {
  name = "radarr";
  apiGroup = "radarr-api";
}
