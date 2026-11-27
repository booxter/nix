{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (ps: [ ps.sabctools ]);
  fixtures = pkgs.runCommand "sabnzbd-cancel-repair-fixtures" { } ''
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
    virtualisation.memorySize = 1024;

    services.sabnzbd = {
      enable = true;
      package = sabnzbd;
      settings = {
        logging.log_level = 2;
        misc = {
          host = "127.0.0.1";
          port = 8080;
          api_key = "0123456789abcdef0123456789abcdef";
          download_dir = "/var/lib/sabnzbd/incomplete";
          complete_dir = "/var/lib/sabnzbd/complete";
          direct_unpack = false;
          auto_browser = false;
        };
        servers.fixture = {
          name = "fixture";
          displayname = "Local NNTP fixture";
          host = "127.0.0.1";
          port = 119;
          connections = 1;
          # Bound connection setup retries against the loopback fixture.
          timeout = 5;
          ssl = false;
        };
      };
    };

    systemd.tmpfiles.rules = [ "d /run/sabnzbd-par2-gate 0700 sabnzbd sabnzbd -" ];
    systemd.services.test-nntp = {
      wantedBy = [ "multi-user.target" ];
      # Use SABnzbd's own end-to-end NNTP fixture; articles are served from
      # the paths encoded in our generated NZB, with real yEnc checksums.
      serviceConfig.ExecStart = "${python}/bin/python ${sabnzbd}/tests/sabnews.py -p 119";
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("sabnzbd.service")
    machine.wait_for_open_port(119)
    machine.wait_for_open_port(8080)
    try:
        print(machine.succeed(
            "${pkgs.python3}/bin/python ${./sabnzbd-cancel-repair/check.py} ${fixtures}/multi-set.nzb",
            timeout=120,
        ))
    except Exception:
        print(machine.succeed("ss -ntp"))
        print(machine.succeed("cat /var/lib/sabnzbd/logs/sabnzbd.log"))
        print(machine.succeed("journalctl -u sabnzbd -u test-nntp --no-pager -n 100"))
        raise
  '';
}
