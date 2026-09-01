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
  topologyChecks = import ./checks/topo {
    inherit
      autoUpgradeEvaluation
      fleetInventory
      lib
      pkgs
      ;
  };
  pythonQualityCheck = import ./checks/python-quality.nix { inherit lib pkgs; };
in
appSet.packages
// topologyChecks
// import ../tests { inherit inputs pkgs; }
// inputNixosTests
// {
  python-quality = pythonQualityCheck;
}
