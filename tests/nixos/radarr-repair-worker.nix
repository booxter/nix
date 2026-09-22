{ pkgs, ... }:
let
  mediaRoot = "/var/lib/radarr-repair-test-media";
  socketPath = "/run/radarr-repair-worker/worker.sock";
in
pkgs.testers.runNixOSTest {
  name = "radarr-repair-worker";

  nodes.machine = {
    imports = [
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
          extraGroups = [ "radarr-repair-worker-clients" ];
        };
        worker-outsider = {
          isSystemUser = true;
          group = "worker-outsider";
        };
      };

      systemd.tmpfiles.rules = [ "d ${mediaRoot} 0750 root media -" ];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("radarr-repair-worker.service")

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
