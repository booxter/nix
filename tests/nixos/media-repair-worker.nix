{ inputs, pkgs, ... }:
let
  mediaRoot = "/var/lib/media-repair-test-media";
  socketPath = "/run/media-repair-worker/worker.sock";
in
pkgs.testers.runNixOSTest {
  name = "media-repair-worker";

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/media-repair
    ];

    config = {
      host.mediaRepair.worker = {
        enable = true;
        roots."root:downloads" = mediaRoot;
      };

      users.groups = {
        media = { };
        worker-client = { };
        worker-outsider = { };
      };
      users.users = {
        worker-client = {
          isSystemUser = true;
          group = "worker-client";
          extraGroups = [ "media-repair-worker-clients" ];
        };
        worker-outsider = {
          isSystemUser = true;
          group = "worker-outsider";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${mediaRoot} 0750 root media -"
        "d ${mediaRoot}/.media-repair 2750 media-repair-worker media -"
      ];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("media-repair-worker.service")

    response = machine.succeed(
        "runuser -u worker-client -- ${pkgs.curl}/bin/curl --silent --output /dev/null "
        "--write-out '%{http_code}' --request POST --header 'Content-Type: application/json' "
        "--data '{}' --unix-socket ${socketPath} http://localhost/v1/probe"
    ).strip()
    assert response == "400", response
    response = machine.succeed(
        "runuser -u worker-client -- ${pkgs.curl}/bin/curl --silent --output /dev/null "
        "--write-out '%{http_code}' --request POST --header 'Content-Type: application/json' "
        "--data '{}' --unix-socket ${socketPath} http://localhost/v1/join/stage"
    ).strip()
    assert response == "400", response
    response = machine.succeed(
        "runuser -u worker-client -- ${pkgs.curl}/bin/curl --silent --output /dev/null "
        "--write-out '%{http_code}' --request POST --header 'Content-Type: application/json' "
        "--data '{}' --unix-socket ${socketPath} http://localhost/v1/join/publish"
    ).strip()
    assert response == "400", response
    response = machine.succeed(
        "runuser -u worker-client -- ${pkgs.curl}/bin/curl --silent --output /dev/null "
        "--write-out '%{http_code}' --request POST --header 'Content-Type: application/json' "
        "--data '{}' --unix-socket ${socketPath} http://localhost/v1/join/discard"
    ).strip()
    assert response == "400", response
    machine.fail(
        "runuser -u worker-outsider -- ${pkgs.curl}/bin/curl --silent "
        "--connect-timeout 1 --unix-socket ${socketPath} http://localhost/v1/probe"
    )
  '';
}
