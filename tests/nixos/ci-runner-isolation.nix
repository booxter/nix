{ pkgs, ... }:
let
  build = pkgs.writeText "runner-build.nix" ''
    builtins.derivation {
      name = "isolated-runner-build";
      system = "${pkgs.stdenv.hostPlatform.system}";
      builder = (builtins.storePath "${pkgs.bash}") + "/bin/bash";
      args = [ "-c" "echo built-through-daemon > $out" ];
    }
  '';
  probe = pkgs.writers.writePython3 "runner-probe" { } ''
    import json
    import os
    from pathlib import Path
    import pwd
    import socket
    import subprocess
    import sys

    state = Path(os.environ["RUNNER_ROOT"])
    home = Path(os.environ["HOME"])
    registration = {"agentId": 1, "agentName": "isolated"}
    if sys.argv[1] == "configure":
        assert sys.argv[sys.argv.index("--pat") + 1] == "registration-only"
        for name in [".credentials", ".credentials_rsaparams", ".runner"]:
            (state / name).write_text(json.dumps(registration))
        (state / "_diag").mkdir(exist_ok=True)
    else:
        for name in [".credentials", ".credentials_rsaparams", ".runner"]:
            assert json.loads((state / name).read_text()) == registration
            assert json.loads((home / name).read_text()) == registration
        assert pwd.getpwuid(os.getuid()).pw_name.startswith("github-runner-")
        assert socket.gethostbyname("runner-target.test") == "127.0.0.1"
        for path in [
            "/run/secrets/host-secret",
            "/run/secrets/registration-token",
            "/etc/host-only",
            "/home/operator/private",
            "/root/private",
            "/var/cache/github-runner/other/private",
        ]:
            assert not os.path.lexists(path), path
        credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
        for token in [
            state / ".current-token",
            credentials / "registration-token",
        ]:
            try:
                token.read_text()
            except PermissionError:
                pass
            else:
                raise AssertionError(f"registration token is readable: {token}")
        credential = credentials / "attic-ci.toml"
        assert credential.read_text() == "job-credential"
        assert not (home / "previous-job").exists()
        (home / "previous-job").write_text("disposable")
        info = json.loads(subprocess.check_output(
            ["nix", "store", "info", "--json"], text=True
        ))
        assert info["trusted"] is False, info
        subprocess.run([
            "nix", "build", "--file",
            "${build}",
            "--out-link", str(home / "result"),
        ], check=True)
        assert (home / "result").read_text() == "built-through-daemon\n"
        subprocess.run([os.environ["REAL_RUNNER"], "--version"], check=True)
        subprocess.run(["/bin/sh", "-c", "/usr/bin/env true"], check=True)
        cache = Path(os.environ["NIX_CACHE_HOME"])
        cache.mkdir(parents=True, exist_ok=True)
        count = cache / "runs"
        runs = int(count.read_text()) if count.exists() else 0
        count.write_text(str(runs + 1))
  '';
  runner = pkgs.lib.makeOverridable (
    _:
    pkgs.writeShellScriptBin "Runner.Listener" ''
      exec ${probe} "$@"
    ''
  ) { };
in
pkgs.testers.runNixOSTest {
  name = "ci-runner-isolation";

  nodes.machine = { lib, ... }: {
    imports = [ ../../nixos/_mixins/ci/sandbox.nix ];
    nix.settings = {
      experimental-features = [ "nix-command" ];
      trusted-users = [ "root" ];
      substituters = lib.mkForce [ ];
    };
    networking.hosts."127.0.0.1" = [ "runner-target.test" ];
    systemd.tmpfiles.rules = [
      # Existing DynamicUser services leave this private state layout on hosts.
      "d /var/lib/private 0700 root root -"
      "d /var/lib/private/github-runner/isolated 0700 nobody nogroup -"
      "d /var/lib/github-runner 0755 root root -"
      "L /var/lib/github-runner/isolated - - - - ../private/github-runner/isolated"
      "d /run/secrets 0755 root root -"
      "f /run/secrets/host-secret 0644 root root - host-secret"
      "f /run/secrets/registration-token 0600 root root - registration-only"
      "f /run/secrets/ci-upload 0400 root root - job-credential"
      "f /etc/host-only 0644 root root - host-file"
      "d /home/operator 0755 root root -"
      "f /home/operator/private 0644 root root - host-home"
      "f /root/private 0644 root root - root-home"
      "d /var/cache/github-runner/other 0755 root root -"
      "f /var/cache/github-runner/other/private 0644 root root - other-runner"
    ];
    services.github-runners.isolated = {
      enable = true;
      package = runner;
      url = "https://github.com/example/test";
      tokenFile = "/run/credentials/github-runner-isolated.service/registration-token";
      tokenType = "access";
      ephemeral = true;
      extraEnvironment = {
        NIX_CACHE_HOME = "/var/cache/github-runner/isolated/nix";
        REAL_RUNNER = "${pkgs.github-runner}/bin/Runner.Listener";
      };
      serviceOverrides = {
        Restart = lib.mkForce "no";
        CacheDirectory = "github-runner/isolated";
        CacheDirectoryMode = "0700";
        LoadCredential = [
          "registration-token:/run/secrets/registration-token"
          "attic-ci.toml:/run/secrets/ci-upload"
        ];
      };
    };
  };

  testScript = ''
    machine.start()
    cache = "/var/cache/github-runner/isolated/nix/runs"
    with subtest("registration and builds work inside the isolated root"):
        machine.wait_until_succeeds(f"test $(cat {cache}) = 1", timeout=60)
        machine.succeed("test -f /run/secrets/host-secret")
        machine.succeed("test -f /etc/host-only")

    with subtest("a fresh job keeps its cache and discards its workspace"):
        machine.succeed("systemctl restart github-runner-isolated.service")
        machine.wait_until_succeeds(f"test $(cat {cache}) = 2", timeout=60)
  '';
}
