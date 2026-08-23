{
  autoUpgradeEvaluation,
  fleetInventory,
  lib,
  pkgs,
}:
let
  checkFiles = lib.filterAttrs (
    name: type: name != "default.nix" && type == "regular" && lib.hasSuffix ".nix" name
  ) (builtins.readDir ./.);
  availableArgs = {
    inherit autoUpgradeEvaluation fleetInventory lib;
  };
in
lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
  lib.mapAttrs' (
    fileName: _:
    let
      type = lib.removeSuffix ".nix" fileName;
      checkName = "topo-${type}";
      check = import (./. + "/${fileName}");
      errors = check (lib.intersectAttrs (builtins.functionArgs check) availableArgs);
    in
    lib.nameValuePair checkName (
      assert lib.assertMsg (errors == [ ]) (lib.concatStringsSep "; " errors);
      pkgs.runCommand checkName { } ''
        touch "$out"
      ''
    )
  ) checkFiles
)
