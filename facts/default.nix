{ lib }:
let
  factsLib = import ./lib.nix { inherit lib; };
  context = {
    lanDomain = "home.arpa";
    frame = "frame";
  };
in
factsLib.loadModules {
  directory = ./.;
  commonArgs = {
    inherit context lib;
  };
}
