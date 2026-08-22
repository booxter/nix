{
  appSet,
  autoUpgradeEvaluation,
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
in
appSet.packages // autoUpgradeChecks // import ../tests { inherit inputs pkgs; } // inputNixosTests
