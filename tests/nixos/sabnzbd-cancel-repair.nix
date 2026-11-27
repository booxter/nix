{ pkgs, ... }:
let
  fixtures = pkgs.runCommand "sabnzbd-cancel-repair-fixtures" { } ''
    export PYTHONPATH=${./lib}
    ${pkgs.python3}/bin/python ${./sabnzbd-cancel-repair/fixtures.py} \
      "$out" ${pkgs.par2cmdline-turbo}/bin/par2
  '';
  gatedPar2 = pkgs.writeScriptBin "par2" ''
    #!${pkgs.python3}/bin/python
    import runpy
    import sys

    sys.argv.insert(1, "${pkgs.par2cmdline-turbo}/bin/par2")
    runpy.run_path("${./sabnzbd-cancel-repair/par2-gate.py}", run_name="__main__")
  '';
  sabnzbd = pkgs.sabnzbd.override { par2cmdline-turbo = gatedPar2; };
in
pkgs.testers.runNixOSTest {
  name = "sabnzbd-cancel-repair";

  nodes.machine = {
    imports = [ ./lib/sabnzbd.nix ];
    virtualisation.memorySize = 1024;

    services.sabnzbd = {
      package = sabnzbd;
      # Bound connection setup retries against the loopback fixture.
      settings.servers.fixture.timeout = 5;
    };

    systemd.tmpfiles.rules = [ "d /run/sabnzbd-par2-gate 0700 sabnzbd sabnzbd -" ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("sabnzbd.service")
    machine.wait_for_open_port(119)
    machine.wait_for_open_port(8080)
    try:
        print(machine.succeed(
            "PYTHONPATH=${./lib} ${pkgs.python3}/bin/python ${./sabnzbd-cancel-repair/check.py} ${fixtures}/multi-set.nzb",
            timeout=120,
        ))
    except Exception:
        print(machine.succeed("ss -ntp"))
        print(machine.succeed("cat /var/lib/sabnzbd/logs/sabnzbd.log"))
        print(machine.succeed("journalctl -u sabnzbd -u test-nntp --no-pager -n 100"))
        raise
  '';
}
