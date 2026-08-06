{
  fleet,
  packageUpdates,
  pkgs,
  proxmox,
  sops,
}:
let
  appSpec = import ./app-spec.nix;
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
