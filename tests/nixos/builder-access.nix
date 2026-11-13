{ pkgs, ... }:
let
  keys = pkgs.runCommand "builder-access-test-keys" { nativeBuildInputs = [ pkgs.nix ]; } ''
    mkdir -p "$out"
    for node in client server server2 rogue; do
      NIX_STATE_DIR="$TMPDIR/state" nix-store --generate-binary-cache-key "$node" "$out/$node.secret" "$out/$node.pub"
    done
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
    in rec {
      simple = make "untrusted-remote-build" "echo remote-build > $out";
      inherit dependency;
      dependent = make "untrusted-dependent-build" "''${coreutils}/bin/cat ''${dependency} > $out";
      remoteDependent = make "untrusted-remote-dependent-build" "''${coreutils}/bin/cat ''${simple} > $out";
    }
  '';
  server = { lib, ... }: {
    imports = [ ../../common/_mixins/builders/server.nix ];
    options.host = {
      realm = lib.mkOption { type = lib.types.str; };
      nix.builder = lib.mkOption { type = lib.types.attrs; };
    };
    config = {
      host.realm = "home";
      host.nix.builder.uses = [ "build" ];
      _module.args.sshKeys.builders.build = builtins.readFile (sshKeys + "/client-key.pub");
      users.users.operator.isNormalUser = true;
      nix.settings.trusted-users = [ "root" ];
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
in
pkgs.testers.runNixOSTest {
  name = "builder-access";
  node.specialArgs.system = pkgs.stdenv.hostPlatform.system;

  defaults = {
    nix.package = pkgs.nix;
    nix.settings = {
      experimental-features = [ "nix-command" ];
      substituters = pkgs.lib.mkForce [ ];
      secret-key-files = [ "/etc/nix/signing-key" ];
      trusted-public-keys = map (node: builtins.readFile "${keys}/${node}.pub") [
        "client"
        "server"
        "server2"
      ];
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
      programs.ssh.knownHosts.server2.publicKeyFile = sshKeys + "/server-key.pub";
    };
    inherit server;
    server2 = {
      imports = [ server ];
      nix.settings.trusted-public-keys = pkgs.lib.mkForce [ (builtins.readFile "${keys}/server.pub") ];
    };
  };

  testScript = ''
    import json
    import shlex

    start_all()
    server.wait_for_unit("sshd.service")
    server2.wait_for_unit("sshd.service")
    client.wait_for_unit("multi-user.target")
    client.succeed("install -m 600 ${sshKeys}/client-key /root/builder-key")

    ssh = "ssh -n -o BatchMode=yes -o ConnectTimeout=10 -i /root/builder-key"
    def build_on(host, attribute):
        builder = f"ssh-ng://nix-ssh@{host} ${pkgs.stdenv.hostPlatform.system} /root/builder-key 1 1"
        return client.succeed(
            "nix-build ${expression} --no-out-link --max-jobs 0 --builders "
            + shlex.quote(builder) + " -A " + attribute
        ).strip()

    with subtest("the builder connection is untrusted"):
        for host in ["server", "server2"]:
            store = f"ssh-ng://nix-ssh@{host}?ssh-key=/root/builder-key"
            info = json.loads(client.succeed("nix store info --json --store " + shlex.quote(store)))
            assert info["trusted"] is False, info

    with subtest("the key cannot run shell commands or log in as the operator"):
        client.fail(ssh + " nix-ssh@server 'touch /tmp/shell-access'")
        server.fail("test -e /tmp/shell-access")
        client.fail(ssh + " operator@server true")
        client.fail(ssh + " -N -o ExitOnForwardFailure=yes -R 19999:localhost:22 nix-ssh@server")

    with subtest("unsigned locally built dependencies cannot be imported"):
        dependency = client.succeed(
            "nix-build ${expression} -A dependency --no-out-link --option secret-key-files "
            + shlex.quote("") + " --builders " + shlex.quote("")
        ).strip()
        server.fail("test -e " + shlex.quote(dependency))
        builder = "ssh-ng://nix-ssh@server ${pkgs.stdenv.hostPlatform.system} /root/builder-key 1 1"
        failure = client.fail("nix-build ${expression} --no-out-link --max-jobs 0 --builders " + shlex.quote(builder) + " -A dependent 2>&1")
        assert "signature" in failure, failure
        client.succeed("nix store sign --key-file ${keys}/rogue.secret " + shlex.quote(dependency))
        failure = client.fail("nix-build ${expression} --no-out-link --max-jobs 0 --builders " + shlex.quote(builder) + " -A dependent 2>&1")
        assert "signature" in failure, failure

    for node, name in [(client, "client"), (server, "server"), (server2, "server2")]:
        node.succeed(f"install -m 600 ${keys}/{name}.secret /etc/nix/signing-key")
        node.succeed("systemctl restart nix-daemon.service")

    with subtest("locally built inputs are automatically signed"):
        client.succeed("nix-store --delete " + shlex.quote(dependency))
        dependency = client.succeed(
            "nix-build ${expression} -A dependency --no-out-link --builders " + shlex.quote("")
        ).strip()
        output = build_on("server", "dependent")
        assert client.succeed("cat " + shlex.quote(output)).strip() == "local-input"
        server.succeed("test -e " + shlex.quote(output))

    with subtest("remote results retain their signature through the client"):
        output = build_on("server", "simple")
        assert client.succeed("cat " + shlex.quote(output)).strip() == "remote-build"
        server.succeed("test -e " + shlex.quote(output))
        server2.fail("test -e " + shlex.quote(output))
        result = build_on("server2", "remoteDependent")
        assert client.succeed("cat " + shlex.quote(result)).strip() == "remote-build"
        server2.succeed("test -e " + shlex.quote(output))
  '';
}
