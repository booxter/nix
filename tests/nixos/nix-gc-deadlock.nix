{ pkgs, ... }:
let
  inherit (pkgs) lib;
  inherit (import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs)
    snakeOilPrivateKey
    snakeOilPublicKey
    ;
  system = pkgs.stdenv.hostPlatform.system;
  remoteOnly = "gc-deadlock-remote";

  # Instantiate inside the VM so auto-GC can collect its garbage without
  # touching the host store. Tools are source paths to avoid rebuilding them.
  graph = pkgs.writeText "gc-deadlock-graph.nix" ''
    let
      bash = builtins.storePath "${builtins.unsafeDiscardStringContext (lib.getExe pkgs.bash)}";
      coreutils = builtins.storePath "${builtins.unsafeDiscardStringContext (toString pkgs.coreutils)}";
      make = name: attrs: builtins.derivation ({
        inherit name;
        system = "${system}";
        builder = bash;
        PATH = coreutils + "/bin";
      } // attrs);

      remote = make "gc-deadlock-remote" {
        requiredSystemFeatures = [ "${remoteOnly}" ];
        args = [ "-c" "mkdir -p $out; echo remote > $out/file" ];
      };
      substituted = make "gc-deadlock-substituted" {
        args = [ "-c" "mkdir -p $out; echo substitutable > $out/payload" ];
      };
      failing = make "gc-deadlock-failing" {
        args = [ "-c" "while [ ! -e /run/fail-build ]; do sleep 0.1; done; exit 1" ];
      };
      top = make "gc-deadlock-top" {
        args = [ "-c" ("mkdir -p $out; cat " + substituted + "/payload " + remote + "/file " + failing + "/marker > $out/result") ];
      };
    in {
      inherit top substituted remote;
    }
  '';
  buildHook = pkgs.writeShellScript "gc-deadlock-build-hook" ''
    export _NIX_TEST_FREE_SPACE_FILE=/run/free-space-helper
    export _NIX_TEST_GC_SYNC_1=/run/gc-sync
    exec ${pkgs.nix}/bin/nix __build-remote "$@"
  '';
in
pkgs.testers.runNixOSTest {
  name = "nix-gc-deadlock";

  defaults = {
    nix.package = pkgs.nix;
    networking.firewall.enable = false;
  };

  nodes.machine = {
    # Auto-GC and explicit deletion must operate on an isolated, writable store.
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    virtualisation.additionalPaths = [
      graph
      pkgs.bash
      pkgs.coreutils
      snakeOilPrivateKey
      buildHook
    ];
    environment.systemPackages = [
      pkgs.openssh
      pkgs.procps
      pkgs.util-linux
    ];

    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        hostName = "builder";
        protocol = "ssh-ng";
        sshUser = "nix-ssh";
        sshKey = "/root/.ssh/id_ecdsa";
        inherit system;
        maxJobs = 1;
        # Keep the failing build local so it can observe /run/fail-build.
        mandatoryFeatures = [ remoteOnly ];
      }
    ];
    nix.settings = {
      max-jobs = 1;
      min-free = 1024 * 1024 * 1024;
      max-free = 2 * 1024 * 1024 * 1024;
      min-free-check-interval = 0;
      substituters = lib.mkForce [ "file:///tmp/cache" ];
      require-sigs = false;
      sandbox = false;
      build-hook = "${buildHook}";
    };
    systemd.services.nix-daemon.environment = {
      _NIX_TEST_FREE_SPACE_FILE = "/run/free-space-daemon";
      NIX_SSHOPTS = "-oBatchMode=yes -oConnectTimeout=10 -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no";
    };
    # Independent free-space readings let the helper acquire gc.lock before
    # the daemon's substitution thread starts its own synchronous auto-GC.
    systemd.tmpfiles.rules =
      map (process: "f /run/free-space-${process} 0644 root root - 1099511627776")
        [
          "daemon"
          "helper"
        ];
  };

  nodes.builder = {
    nix.settings.system-features = [ remoteOnly ];
    nix.sshServe = {
      enable = true;
      protocol = "ssh-ng";
      trusted = true;
      keys = [ snakeOilPublicKey ];
    };
  };

  testScript = ''
    import datetime

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nix-daemon.socket")
    builder.wait_for_unit("sshd.service")
    machine.succeed("install -Dm600 ${snakeOilPrivateKey} /root/.ssh/id_ecdsa")

    # Cache an input, then delete its output while retaining its derivation.
    # The top-level build must substitute it alongside local and remote builds.
    local_store = "--store local --option min-free 0 --option max-free 0"
    for attribute in ["substituted", "remote", "top"]:
        machine.succeed(
            f"nix-instantiate {local_store} -A {attribute} ${graph} > /run/{attribute}.drv"
        )
    machine.succeed(f"nix-store {local_store} --realise $(cat /run/substituted.drv)")
    machine.succeed("nix-store -q --outputs $(cat /run/substituted.drv) > /run/substituted.out")
    machine.succeed(
        f"nix --extra-experimental-features nix-command {local_store} copy "
        "--to file:///tmp/cache $(cat /run/substituted.out)"
    )
    machine.succeed(f"nix-store {local_store} --delete $(cat /run/substituted.out)")
    machine.succeed("nix-store -q --outputs $(cat /run/top.drv) > /run/top.out")

    # Deletion logs must exceed the helper's stderr pipe capacity. Otherwise a
    # worker blocked joining the substitution thread would not stop its GC.
    machine.succeed("mkdir -p /tmp/garbage")
    machine.succeed("for i in $(seq 1 6000); do echo $i > /tmp/garbage/$i; done")
    machine.succeed(
        "nix-store --option min-free 0 --option max-free 0 --add /tmp/garbage/* > /run/garbage-paths"
    )

    # Hold substitution before addToStore(), and hold the helper's GC after it
    # acquires gc.lock. These are Nix's existing GC test hooks.
    machine.succeed(
        'nar=$(find /tmp/cache/nar -type f | head -n1); '
        'mv "$nar" /run/cache-nar.bin; mkfifo "$nar"; echo "$nar" > /run/cache-nar.fifo'
    )
    machine.succeed("mkfifo /run/gc-sync")
    machine.succeed("echo 1024 > /run/free-space-helper")
    machine.succeed(
        "(status=0; nix-store --store daemon --realise "
        "$(cat /run/top.drv) $(cat /run/remote.drv) || status=$?; "
        'echo "$status" > /run/client.status) > /run/client.log 2>&1 &'
    )
    machine.wait_until_succeeds(
        "pgrep -f '[n]ix __build-remote' >/dev/null && ! flock -n /nix/var/nix/gc.lock true",
        timeout=datetime.timedelta(seconds=60),
    )

    machine.succeed(
        "setsid sh -c '"
        'exec 3>"$(cat /run/cache-nar.fifo)"; '
        "touch /run/nar-opened; "
        "while [ ! -e /run/release-nar ]; do sleep 0.05; done; "
        "cat /run/cache-nar.bin >&3; touch /run/nar-served"
        "' >/dev/null 2>&1 &"
    )
    machine.wait_until_succeeds("test -e /run/nar-opened")
    machine.succeed("echo 1024 > /run/free-space-daemon; touch /run/release-nar")
    machine.wait_until_succeeds("test -e /run/nar-served")
    machine.succeed(
        'rm "$(cat /run/cache-nar.fifo)"; cp /run/cache-nar.bin "$(cat /run/cache-nar.fifo)"'
    )

    # Open the GC FIFO before failing the build: a fixed worker may terminate
    # its helper during cleanup, so opening it afterwards could block forever.
    machine.succeed(
        "setsid sh -c '"
        "exec 3>/run/gc-sync; touch /run/gc-ready; "
        "while [ ! -e /run/release-gc ]; do sleep 0.05; done; echo go >&3"
        "' >/dev/null 2>&1 &"
    )
    machine.wait_until_succeeds("test -e /run/gc-ready")

    # Wait for the substitution thread's auto-GC to block on the helper's lock,
    # then make the worker abandon its goals before releasing the collector.
    machine.wait_until_succeeds("grep -F 'waiting for the big garbage collector lock' /run/client.log")
    machine.succeed("touch /run/fail-build")
    machine.wait_until_succeeds("grep -F 'Reason: builder failed with exit code 1' /run/client.log")
    machine.succeed("touch /run/release-gc")

    with subtest("failed builds finish without a GC log deadlock"):
        try:
            machine.wait_until_succeeds("test -e /run/client.status", timeout=datetime.timedelta(seconds=120))
            status = int(machine.succeed("cat /run/client.status").strip())
            assert status != 0, "the build with a failing dependency unexpectedly succeeded"
            machine.succeed("grep -F gc-deadlock-failing /run/client.log")
            machine.wait_until_succeeds("flock -n /nix/var/nix/gc.lock true")
            machine.fail("test -e $(cat /run/top.out)")
            machine.succeed("timeout 10 nix-store --store daemon --query --hash ${pkgs.bash}")
        except Exception:
            print(machine.succeed("cat /run/client.log"))
            print(machine.succeed("ps -eLo pid,ppid,tid,wchan:32,args; lslocks"))
            raise
  '';
}
