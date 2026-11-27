{ pkgs, ... }:
let
  fixtures = pkgs.runCommand "sabnzbd-repair-capacity-fixtures" { } ''
    export PYTHONPATH=${./lib}
    ${pkgs.python3}/bin/python ${./sabnzbd-repair-capacity/fixtures.py} \
      "$out" ${pkgs.par2cmdline-turbo}/bin/par2
  '';
in
pkgs.testers.runNixOSTest {
  name = "sabnzbd-repair-capacity";

  nodes.machine = {
    imports = [ ./lib/sabnzbd.nix ];
    virtualisation.memorySize = 1024;
    services.sabnzbd = {
      package = pkgs.sabnzbd;
      # Preserve the offsets of articles omitted from the NZB as sparse holes.
      settings.misc.direct_write = true;
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
            "PYTHONPATH=${./lib} ${pkgs.python3}/bin/python ${./sabnzbd-repair-capacity/check.py} ${fixtures}",
            timeout=timedelta(seconds=180),
        ))
    except Exception:
        print(machine.succeed("cat /var/lib/sabnzbd/logs/sabnzbd.log"))
        print(machine.succeed("journalctl -u sabnzbd -u test-nntp --no-pager -n 100"))
        raise
  '';
}
