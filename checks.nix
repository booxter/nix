{
  fact,
  facts,
  fleet,
  packageUpdates,
  pkgs,
  proxmox,
}:
{
  fact =
    let
      factNames = builtins.attrNames facts;
      expectedNames = pkgs.lib.concatStringsSep "\n" factNames;
      sampleName = builtins.head factNames;
      expectedJson = builtins.toJSON facts.${sampleName};
    in
    pkgs.runCommand "fact-check" { } ''
      test "$(${fact}/bin/fact --list)" = ${pkgs.lib.escapeShellArg expectedNames}
      test "$(${fact}/bin/fact ${pkgs.lib.escapeShellArg sampleName})" = ${pkgs.lib.escapeShellArg expectedJson}
      if ${fact}/bin/fact unknown >/dev/null 2>&1; then
        echo "unknown fact library unexpectedly succeeded" >&2
        exit 1
      fi
      touch "$out"
    '';

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
  backup = import ./tests/nixos/backup.nix { inherit pkgs; };
  blackbox = import ./tests/nixos/blackbox.nix { inherit pkgs; };
  oauth2-proxy-gate = import ./tests/nixos/oauth2-proxy-gate.nix { inherit pkgs; };
  qos = import ./tests/nixos/qos.nix { inherit pkgs; };
}
