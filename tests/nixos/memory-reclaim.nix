{ pkgs, ... }:
let
  fixture = pkgs.runCommand "thp-reclaim-fixture" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
    mkdir -p "$out/bin"
    cc -Wall -Wextra -Werror ${./fixtures/thp-reclaim.c} -o "$out/bin/thp-reclaim-fixture"
  '';
in
pkgs.testers.runNixOSTest {
  name = "memory-reclaim";
  nodes.machine = { lib, ... }: {
    imports = [ ../../nixos/_mixins/memory-reclaim ];
    host.memoryReclaim = {
      enable = true;
      package = pkgs.oomd;
      cgroups = [ "system.slice/thp-fixture.service" ];
      reserveMiB = 4;
      intervalSeconds = 2;
    };
    # Establish the retained-memory baseline before starting the reclaimer.
    systemd.services.oomd-reclaim.wantedBy = lib.mkForce [ ];
    systemd.services.thp-fixture = {
      serviceConfig = {
        ExecStart = "${fixture}/bin/thp-reclaim-fixture";
        MemoryAccounting = true;
        MemoryMax = "128M";
        MemorySwapMax = 0;
      };
    };
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl start thp-fixture")
    machine.wait_for_file("/run/thp-ready")
    group = "/sys/fs/cgroup/system.slice/thp-fixture.service"

    def usage():
        return int(machine.succeed(f"cat {group}/memory.current"))

    before = usage()
    assert before > 30 * 1024 * 1024, before
    stats = dict(line.split() for line in machine.succeed(f"cat {group}/memory.stat").splitlines())
    assert int(stats["anon"]) < 1024 * 1024, stats
    print(f"Charged bytes before reclaim: {before}")
    machine.succeed("systemctl start oomd-reclaim")
    try:
        machine.wait_until_succeeds(f"test $(cat {group}/memory.current) -lt 8388608", timeout=90)
    finally:
        print(machine.succeed(f"cat {group}/memory.current {group}/memory.stat {group}/memory.pressure {group}/io.pressure"))
    assert before - usage() > 24 * 1024 * 1024
    machine.sleep(3)
    machine.succeed("systemctl is-active thp-fixture oomd-reclaim")
    assert machine.succeed(f"cat {group}/memory.high").strip() == "max"
    machine.succeed(f"grep -qx 'oom_kill 0' {group}/memory.events")
    machine.succeed("systemctl stop oomd-reclaim thp-fixture")
  '';
}
