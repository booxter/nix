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
  dashboardCatalogErrors = import ./checks/dashboard-catalog.nix {
    inherit fleetInventory lib;
  };
  dashboardCatalogChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    dashboard-catalog =
      assert lib.assertMsg (dashboardCatalogErrors == [ ]) (
        lib.concatStringsSep "; " dashboardCatalogErrors
      );
      pkgs.runCommand "dashboard-catalog" { } ''
        touch "$out"
      '';
  };
  upsTopologyErrors = import ./checks/ups-topology.nix {
    inherit fleetInventory lib;
  };
  upsTopologyChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    ups-topology =
      assert lib.assertMsg (upsTopologyErrors == [ ]) (lib.concatStringsSep "; " upsTopologyErrors);
      pkgs.runCommand "ups-topology" { } ''
        touch "$out"
      '';
  };
  proxmoxTopologyErrors = import ./checks/proxmox-topology.nix {
    inherit fleetInventory lib;
  };
  proxmoxTopologyChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    proxmox-topology =
      assert lib.assertMsg (proxmoxTopologyErrors == [ ]) (
        lib.concatStringsSep "; " proxmoxTopologyErrors
      );
      pkgs.runCommand "proxmox-topology" { } ''
        touch "$out"
      '';
  };
in
appSet.packages
// autoUpgradeChecks
// dashboardCatalogChecks
// proxmoxTopologyChecks
// upsTopologyChecks
// import ../tests { inherit inputs pkgs; }
// inputNixosTests
