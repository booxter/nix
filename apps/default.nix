{
  inputs,
  pkgs,
  system,
  username,
}:
let
  appSpec = import ./app-spec.nix;
  sops = import ./sops {
    sopsTools = pkgs.sops-tools;
  };
  packageUpdates = import ./package-updates { inherit pkgs; };
  fleet = import ./fleet.nix {
    inherit pkgs username;
  };
  proxmox = import ./proxmox.nix {
    inherit inputs system;
  };
  appSpecs =
    sops.appSpecs
    // packageUpdates.appSpecs
    // fleet.appSpecs
    // proxmox.appSpecs
    // {
      get-ff-cookie = appSpec (pkgs.lib.getExe pkgs.get-ff-cookie) "Export Firefox cookies as Netscape cookies.txt on stdout.";
      flake-input-update-summary = appSpec (pkgs.lib.getExe pkgs.flake-input-update-summary) "Generate a revision-linked flake input update summary.";
    };
  mkApp = _name: appSpec: {
    type = "app";
    inherit (appSpec) program;
    meta.description = appSpec.description;
  };
in
pkgs.lib.mapAttrs mkApp appSpecs
