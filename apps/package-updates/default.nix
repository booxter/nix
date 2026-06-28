{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  updatePackages = pkgs.writeShellApplication {
    name = "update-packages";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      git
      gnused
      jq
      nix
      nix-update
      prefetch-npm-deps
    ];
    text = ''
      export PACKAGE_UPDATE_TARGETS_FILE="''${PACKAGE_UPDATE_TARGETS_FILE:-${./targets.json}}"
      exec ${pkgs.bash}/bin/bash ${./update-packages.sh} "$@"
    '';
  };

  updateOciImages = pkgs.writeShellApplication {
    name = "update-oci-images";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      jq
      skopeo
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${./update-oci-images.sh} "$@"
    '';
  };
in
{
  update-packages = mkApp "${updatePackages}/bin/update-packages" "Update selected fetched packages and write a changelog-linked PR summary.";
  update-oci-images = mkApp "${updateOciImages}/bin/update-oci-images" "Update selected OCI image tags and write a changelog-linked PR summary.";
}
