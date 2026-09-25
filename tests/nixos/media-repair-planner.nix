{ inputs, pkgs, ... }:
let
  socketPath = "/run/media-repair-planner.sock";
in
pkgs.testers.runNixOSTest {
  name = "media-repair-planner";

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/media-repair
      ../../nixos/_mixins/web/options.nix
      ./lib/sops.nix
    ];

    config = {
      host.mediaRepair.planner.enable = true;

      testSupport.sops.values."radarr-repair/openrouter-api-key" = "test-openrouter-key";

      users.users = {
        planner-client = {
          isSystemUser = true;
          group = "planner-client";
          extraGroups = [ "media-repair-planner-clients" ];
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
    machine.wait_for_unit("media-repair-planner.socket")

    response = machine.succeed(
        "runuser -u planner-client -- "
        "${pkgs.curl}/bin/curl --fail --silent "
        "--unix-socket ${socketPath} http://localhost/ready"
    )
    assert json.loads(response) == {"status": "ready"}
    machine.wait_for_unit("media-repair-planner.service")

    machine.fail(
        "runuser -u planner-outsider -- "
        "${pkgs.curl}/bin/curl --fail --silent --connect-timeout 1 "
        "--unix-socket ${socketPath} http://localhost/ready"
    )
  '';
}
