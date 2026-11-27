{ pkgs, ... }:
let
  fixtures = pkgs.runCommand "sabnzbd-repair-glob-fixtures" { } ''
    export PYTHONPATH=${./lib}
    ${pkgs.python3}/bin/python ${./sabnzbd-repair-glob/fixtures.py} \
      "$out" ${pkgs.par2cmdline-turbo}/bin/par2
  '';
in
pkgs.testers.runNixOSTest {
  name = "sabnzbd-repair-glob";

  nodes.machine = {
    imports = [ ./lib/sabnzbd.nix ];
    virtualisation.memorySize = 1024;
    services.sabnzbd = {
      package = pkgs.sabnzbd;
      settings.misc.direct_write = true;
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("sabnzbd.service")
    machine.wait_for_open_port(119)
    machine.wait_for_open_port(8080)
    print(machine.succeed(
        "PYTHONPATH=${./lib} ${pkgs.python3}/bin/python ${./sabnzbd-repair-glob/check.py} ${fixtures}",
    ))
  '';
}
