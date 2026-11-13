{ pkgs, ... }:
let
  keys = pkgs.runCommand "builder-access-test-keys" { nativeBuildInputs = [ pkgs.nix ]; } ''
    mkdir -p "$out"
    NIX_STATE_DIR="$TMPDIR/state" nix-store --generate-binary-cache-key builder-access-test "$out/cache.secret" "$out/cache.pub"
  '';
  sshKeys = ./backup;
  expression = pkgs.writeText "builder-access.nix" ''
    let
      bash = builtins.storePath "${pkgs.bash}";
      coreutils = builtins.storePath "${pkgs.coreutils}";
      make = name: script: builtins.derivation {
        inherit name;
        system = "${pkgs.stdenv.hostPlatform.system}";
        builder = "''${bash}/bin/bash";
        args = [ "-c" script ];
      };
      dependency = make "unsigned-local-input" "echo local-input > $out";
    in {
      simple = make "untrusted-remote-build" "echo remote-build > $out";
      inherit dependency;
      dependent = make "untrusted-dependent-build" "''${coreutils}/bin/cat ''${dependency} > $out";
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "builder-access";

  defaults = {
    nix.package = pkgs.nix;
    nix.settings = {
      experimental-features = [ "nix-command" ];
      substituters = pkgs.lib.mkForce [ ];
    };
    environment.systemPackages = [
      pkgs.bash
      pkgs.coreutils
      pkgs.openssh
    ];
  };

  nodes = {
    client = {
      programs.ssh.knownHosts.server.publicKeyFile = sshKeys + "/server-key.pub";
    };
    server = {
      users.users = {
        remote-builder = {
          isSystemUser = true;
          group = "remote-builder";
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = [
            ''restrict,command="${pkgs.nix}/bin/nix-daemon --stdio" ${
              builtins.readFile (sshKeys + "/client-key.pub")
            }''
          ];
        };
        operator.isNormalUser = true;
      };
      users.groups.remote-builder = { };
      nix.settings = {
        allowed-users = [ "remote-builder" ];
        trusted-users = [ "root" ];
        trusted-public-keys = [ (builtins.readFile "${keys}/cache.pub") ];
      };
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };
      systemd.tmpfiles.rules = [
        "C /etc/ssh/ssh_host_ed25519_key 0600 root root - ${sshKeys}/server-key"
      ];
    };
  };

  testScript = ''
    import json
    import shlex

    start_all()
    server.wait_for_unit("sshd.service")
    client.wait_for_unit("multi-user.target")
    client.succeed("install -m 600 ${sshKeys}/client-key /root/builder-key")

    ssh = "ssh -n -o BatchMode=yes -o ConnectTimeout=10 -i /root/builder-key"
    store = "ssh-ng://remote-builder@server?ssh-key=/root/builder-key"
    build = "nix-build ${expression} --no-out-link --max-jobs 0 --builders " + shlex.quote(
        "ssh-ng://remote-builder@server ${pkgs.stdenv.hostPlatform.system} /root/builder-key 1 1"
    )

    with subtest("the builder connection is untrusted"):
        info = json.loads(client.succeed("nix store info --json --store " + shlex.quote(store)))
        assert info["trusted"] is False, info

    with subtest("the key cannot run shell commands or log in as the operator"):
        client.fail(ssh + " remote-builder@server 'touch /tmp/shell-access'")
        server.fail("test -e /tmp/shell-access")
        client.fail(ssh + " operator@server true")
        client.fail(ssh + " -N -o ExitOnForwardFailure=yes -R 19999:localhost:22 remote-builder@server")

    with subtest("ordinary remote builds work without Nix trust"):
        output = client.succeed(build + " -A simple").strip()
        assert client.succeed("cat " + shlex.quote(output)).strip() == "remote-build"
        server.succeed("test -e " + shlex.quote(output))

    with subtest("unsigned locally built dependencies cannot be imported"):
        dependency = client.succeed(
            "nix-build ${expression} -A dependency --no-out-link --builders " + shlex.quote("")
        ).strip()
        server.fail("test -e " + shlex.quote(dependency))
        failure = client.fail(build + " -A dependent 2>&1")
        assert "signature" in failure, failure

    with subtest("a trusted store signature allows the same dependency"):
        client.succeed("nix store sign --key-file ${keys}/cache.secret " + shlex.quote(dependency))
        output = client.succeed(build + " -A dependent").strip()
        assert client.succeed("cat " + shlex.quote(output)).strip() == "local-input"
        server.succeed("test -e " + shlex.quote(output))
  '';
}
