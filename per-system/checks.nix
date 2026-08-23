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
  autoUpgradeChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    auto-upgrade-schedule =
      assert lib.assertMsg (autoUpgradeEvaluation.errors == [ ]) (
        lib.concatStringsSep "; " autoUpgradeEvaluation.errors
      );
      pkgs.runCommand "auto-upgrade-schedule" { } ''
        touch "$out"
      '';
  };
  topologyFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
    builtins.readDir ./checks/topo
  );
  topologyChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    lib.mapAttrs' (
      fileName: _:
      let
        type = lib.removeSuffix ".nix" fileName;
        checkName = "topo-${type}";
        errors = import (./checks/topo + "/${fileName}") {
          inherit fleetInventory lib;
        };
      in
      lib.nameValuePair checkName (
        assert lib.assertMsg (errors == [ ]) (lib.concatStringsSep "; " errors);
        pkgs.runCommand checkName { } ''
          touch "$out"
        ''
      )
    ) topologyFiles
  );
in
appSet.packages
// autoUpgradeChecks
// topologyChecks
// import ../tests { inherit inputs pkgs; }
// inputNixosTests
