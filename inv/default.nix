{ lib }:
let
  inventoryLib = import ./lib.nix { inherit lib; };
  context = {
    lanDnsRecordTtlSeconds = 300;
    lanDomain = "home.arpa";
    publicDomain = "ihar.dev";
    frame = "frame";
    mmini = "mmini";
  };
in
inventoryLib.loadModules {
  directory = ./.;
  commonArgs = {
    inherit context lib;
  };
}
