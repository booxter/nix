{
  appSet,
  autoUpgradeEvaluation,
  fleetInventory,
  inputs,
  pkgs,
  system,
  ...
}:
let
  inherit (pkgs) lib;
  checkedInputs = {
    inherit (inputs)
      lolek
      motion-captcha-bot
      ;
  };
  inputNixosTests = lib.concatMapAttrs (
    inputName: input:
    lib.mapAttrs' (checkName: check: lib.nameValuePair "${inputName}-${checkName}" check) (
      lib.filterAttrs (checkName: _: lib.hasPrefix "nixos-" checkName) (input.checks.${system} or { })
    )
  ) checkedInputs;
  topologyChecks = import ./topo {
    inherit
      autoUpgradeEvaluation
      fleetInventory
      lib
      pkgs
      ;
  };
  pythonQualityCheck = import ./python-quality.nix { inherit lib pkgs; };
  nixosTests = import ../../tests { inherit inputs pkgs; } // inputNixosTests;
  batchChecks =
    appSet.packages
    // topologyChecks
    // {
      python-quality = pythonQualityCheck;
      media-repair-contracts = pkgs.media-repair-contracts;
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      repairr-package = pkgs.repairr;
      media-repair-planner = pkgs.media-repair-planner;
    };
  collisions = lib.intersectLists (builtins.attrNames batchChecks) (builtins.attrNames nixosTests);
in
assert lib.assertMsg (collisions == [ ]) (
  "Checks cannot belong to both the batch and NixOS test groups: "
  + lib.concatStringsSep ", " collisions
);
{
  all = batchChecks // nixosTests;
  inherit batchChecks nixosTests;
}
