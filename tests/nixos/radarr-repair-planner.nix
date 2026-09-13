{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  radarrOptions = import ../../nixos/_mixins/radarr/options.nix { inherit lib pkgs; };
  socketPath = "/run/radarr-repair-planner.sock";
in
pkgs.testers.runNixOSTest {
  name = "radarr-repair-planner";

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/radarr/repair.nix
      ./lib/sops.nix
    ];

    options.host.radarr = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { options = radarrOptions; });
      default = null;
    };

    config = {
      host.radarr.repair.planner.enable = true;

      testSupport.sops.values."radarr-repair/openrouter-api-key" = "test-openrouter-key";

      users.users = {
        planner-client = {
          isSystemUser = true;
          group = "planner-client";
          extraGroups = [ "radarr-repair-planner-clients" ];
        };
        planner-outsider = {
          isSystemUser = true;
          group = "planner-outsider";
        };
      };
      users.groups = {
        planner-client = { };
        planner-outsider = { };
      };
    };
  };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("radarr-repair-planner.socket")

    response = machine.succeed(
        "runuser -u planner-client -- "
        "${pkgs.curl}/bin/curl --fail --silent "
        "--unix-socket ${socketPath} http://localhost/ready"
    )
    assert json.loads(response) == {"status": "ready"}
    machine.wait_for_unit("radarr-repair-planner.service")

    machine.fail(
        "runuser -u planner-outsider -- "
        "${pkgs.curl}/bin/curl --fail --silent --connect-timeout 1 "
        "--unix-socket ${socketPath} http://localhost/ready"
    )
  '';
}
