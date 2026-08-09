{ lib }:
let
  inventoryLib = import ./lib.nix { inherit lib; };
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
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
    inherit context lib readPublicKey;
  };
}
