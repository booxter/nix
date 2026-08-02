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
    inventory = import ./lib/inventory.nix { inherit (pkgs) lib; };
    sops = import ./apps/sops {
      hostInventory = inventory;
      inherit pkgs;
    };
    fleet = import ./apps/fleet.nix { inherit pkgs; };
    packageUpdates = import ./apps/package-updates { inherit pkgs; };
    proxmox = import ./apps/proxmox.nix { inherit inputs system; };
  in
  {
    sops-tools = sops.package;
    patch-context = pkgs.patch-context;
    deploy = fleet.packages.deploy;
    diff = fleet.packages.diff;
    get-local-builders = fleet.packages.get-local-builders;
    vm = fleet.packages.vm;
    wg-home-client-config = fleet.packages.wg-home-client-config;
    update-packages = packageUpdates.packages.update-packages;
    update-oci-images = packageUpdates.packages.update-oci-images;
    prox-deploy = proxmox.packages.prox-deploy;
  }
)
