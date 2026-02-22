{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  fleetUpgrade = pkgs.writeShellApplication {
    name = "fleet-upgrade";
    runtimeInputs = with pkgs; [
      bind
      git
      jq
      openssh
      python3
      python3Packages.prompt-toolkit
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../.}/scripts/update-machines.sh "$@"
    '';
  };
in
{
  "fleet-upgrade" =
    mkApp "${fleetUpgrade}/bin/fleet-upgrade" "Update selected machines by deploying this flake to each host.";
}
