{ pkgs, ... }:
let
  fixtures = pkgs.runCommand "sabnzbd-fast-connect-fixtures" { } ''
    export PYTHONPATH=${./lib}
    ${pkgs.python3}/bin/python ${./sabnzbd-fast-connect/fixtures.py} "$out"
  '';
in
pkgs.testers.runNixOSTest {
  name = "sabnzbd-fast-connect";

  nodes.machine = {
    imports = [ ./lib/sabnzbd.nix ];
    virtualisation = {
      cores = 1;
      memorySize = 1024;
    };
    services.sabnzbd.package = pkgs.sabnzbd;

    # On one CPU, FIFO lets a new connection thread finish its immediate
    # loopback connect before its waiting caller can resume. This exercises
    # publication of the connection without patching SABnzbd's Python code.
    systemd.services.sabnzbd.serviceConfig = {
      CPUSchedulingPolicy = "fifo";
      CPUSchedulingPriority = 1;
    };
  };

  testScript = ''
    from datetime import timedelta

    machine.start()
    machine.wait_for_unit("sabnzbd.service")
    machine.wait_for_open_port(119)
    machine.wait_for_open_port(8080)
    try:
        print(machine.succeed(
            "PYTHONPATH=${./lib} ${pkgs.python3}/bin/python ${./sabnzbd-fast-connect/check.py} ${fixtures}",
            timeout=timedelta(seconds=90),
        ))
    except Exception:
        print(machine.succeed("ss -ntp"))
        print(machine.succeed("ps -eLo pid,tid,cls,rtprio,comm"))
        print(machine.succeed("cat /var/lib/sabnzbd/logs/sabnzbd.log"))
        print(machine.succeed("journalctl -u sabnzbd -u test-nntp --no-pager -n 100"))
        raise
  '';
}
