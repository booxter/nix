{
  fleet,
  packageUpdates,
  pkgs,
  proxmox,
}:
{
  get-ff-cookie = pkgs.get-ff-cookie;
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
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  oauth2-proxy-gate = import ./tests/nixos/oauth2-proxy-gate.nix { inherit pkgs; };
}
