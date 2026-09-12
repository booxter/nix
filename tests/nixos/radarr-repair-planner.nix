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

    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("radarr-repair-planner.socket")

    socket = machine.succeed(
        "stat -c '%a:%U:%G' ${socketPath}"
    ).strip()
    assert socket == "660:radarr-repair-planner:radarr-repair-planner-clients", socket
    assert machine.succeed("id -nG radarr-repair-planner").strip() == "radarr-repair-planner"

    response = machine.succeed(
        "runuser -u planner-client -- "
        "curl --fail --silent --unix-socket ${socketPath} http://localhost/ready"
    )
    assert json.loads(response) == {"status": "ready"}
    machine.wait_for_unit("radarr-repair-planner.service")

    machine.fail(
        "runuser -u planner-outsider -- "
        "curl --fail --silent --unix-socket ${socketPath} http://localhost/ready"
    )

    properties = machine.succeed(
        "systemctl show radarr-repair-planner.service "
        "--property=User --property=Group --property=NoNewPrivileges "
        "--property=ProtectHome --property=ProtectSystem --property=PrivateDevices"
    )
    assert "User=radarr-repair-planner" in properties
    assert "Group=radarr-repair-planner" in properties
    assert "NoNewPrivileges=yes" in properties
    assert "ProtectHome=yes" in properties
    assert "ProtectSystem=strict" in properties
    assert "PrivateDevices=yes" in properties
  '';
}
