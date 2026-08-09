{
  fact,
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
      fact = appSpec fact (pkgs.lib.getExe fact) "List fact libraries or print one as JSON.";
      get-ff-cookie =
        appSpec pkgs.get-ff-cookie (pkgs.lib.getExe pkgs.get-ff-cookie)
          "Export Firefox cookies as Netscape cookies.txt on stdout.";
      flake-input-update-summary =
        appSpec pkgs.flake-input-update-summary (pkgs.lib.getExe pkgs.flake-input-update-summary)
          "Generate a revision-linked flake input update summary.";
    };
  mkApp = _name: appSpec: {
    type = "app";
    inherit (appSpec) program;
    meta.description = appSpec.description;
  };
in
{
  apps = pkgs.lib.mapAttrs mkApp appSpecs;
  packages = pkgs.lib.mapAttrs (_: appSpec: appSpec.package) appSpecs;
}
