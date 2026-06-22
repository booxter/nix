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
      coreutils
      git
      jq
      nix
      nix-update
    ];
    text = ''
      export PACKAGE_UPDATE_TARGETS_FILE="''${PACKAGE_UPDATE_TARGETS_FILE:-${./targets.json}}"
      exec ${pkgs.bash}/bin/bash ${./update-packages.sh} "$@"
    '';
  };
in
{
  update-packages = mkApp "${updatePackages}/bin/update-packages" "Update selected fetched packages and write a changelog-linked PR summary.";
}
