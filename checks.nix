{
  inputs,
  helpers,
  outputs,
}:
helpers.forAllSystems (
  system:
  let
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        outputs.overlays.additions
        outputs.overlays.modifications
      ];
    };
    fleet = import ./apps/fleet.nix { inherit pkgs; };
    packageUpdates = import ./apps/package-updates { inherit pkgs; };
    proxmox = import ./apps/proxmox.nix { inherit inputs system; };
    getFfCookie = pkgs.get-ff-cookie;
  in
  {
    get-ff-cookie = getFfCookie;
    join-media-parts = pkgs.join-media-parts;

    sops-tools = pkgs.sops-tools;
    patch-context = pkgs.patch-context;
    deploy = fleet.packages.deploy;
    diff = fleet.packages.diff;
    reset-oidc = fleet.packages.reset-oidc;
    vm = fleet.packages.vm;
    wg-home-client-config = fleet.packages.wg-home-client-config;
    update-packages = packageUpdates.packages.update-packages;
    update-oci-images = packageUpdates.packages.update-oci-images;
    prox-deploy = proxmox.packages.prox-deploy;
  }
)
