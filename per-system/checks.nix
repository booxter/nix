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
  observabilityTopologyErrors = import ./checks/observability-topology.nix {
    inherit fleetInventory lib;
  };
  observabilityTopologyChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    observability-topology =
      assert lib.assertMsg (observabilityTopologyErrors == [ ]) (
        lib.concatStringsSep "; " observabilityTopologyErrors
      );
      pkgs.runCommand "observability-topology" { } ''
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
  webIngressErrors = import ./checks/web-ingress.nix {
    inherit fleetInventory lib;
  };
  webIngressChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    web-ingress =
      assert lib.assertMsg (webIngressErrors == [ ]) (lib.concatStringsSep "; " webIngressErrors);
      pkgs.runCommand "web-ingress" { } ''
        touch "$out"
      '';
  };
  webServiceErrors = import ./checks/web-services.nix {
    inherit fleetInventory lib;
  };
  webServiceChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    web-services =
      assert lib.assertMsg (webServiceErrors == [ ]) (lib.concatStringsSep "; " webServiceErrors);
      pkgs.runCommand "web-services" { } ''
        touch "$out"
      '';
  };
  wireguardTopologyErrors = import ./checks/wireguard-topology.nix {
    inherit fleetInventory lib;
  };
  wireguardTopologyChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    wireguard-topology =
      assert lib.assertMsg (wireguardTopologyErrors == [ ]) (
        lib.concatStringsSep "; " wireguardTopologyErrors
      );
      pkgs.runCommand "wireguard-topology" { } ''
        touch "$out"
      '';
  };
in
appSet.packages
// autoUpgradeChecks
// dashboardCatalogChecks
// observabilityTopologyChecks
// proxmoxTopologyChecks
// upsTopologyChecks
// webIngressChecks
// webServiceChecks
// wireguardTopologyChecks
// import ../tests { inherit inputs pkgs; }
// inputNixosTests
