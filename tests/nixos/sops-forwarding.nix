{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  fixtures =
    pkgs.runCommand "sops-forwarding-fixtures"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.openssh
          pkgs.sops
        ];
      }
      ''
        mkdir -p "$out"
        ssh-keygen -q -t ed25519 -N "" -f "$out/ssh"
        for name in alice bob; do
          age-keygen -o "$out/$name.key"
          recipient=$(age-keygen -y "$out/$name.key")
          printf '{"origin":"%s"}' "$name" |
            sops encrypt --age "$recipient" --input-type json --output-type json /dev/stdin > "$out/$name.json"
        done
      '';
  inventory.hosts = lib.genAttrs [ "alice" "bob" ] (name: {
    platform = "nixos";
    realm = "home";
    ssh.knownHostNames = [ name ];
  });
  node = { config, ... }: {
    imports = [ inputs.home-manager.nixosModules.home-manager ];
    options.host = lib.mkOption { type = lib.types.attrs; };
    config = {
      host = {
        realm = "home";
        security.secrets.operator.ageIdentity.path = "/home/operator/.config/sops/age/keys.txt";
      };
      users.users.operator = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
        openssh.authorizedKeys.keyFiles = [ "${fixtures}/ssh.pub" ];
      };
      services.openssh = {
        enable = true;
        extraConfig = ''
          AcceptEnv SOPS_KEYSERVICE SOPS_ENABLE_LOCAL_KEYSERVICE
        '';
      };
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs.fleetInventory = inventory;
        users.operator = {
          imports = [ ../../hm/_mixins/security/sops-forwarding.nix ];
          options.host.hm.env.roles.developer = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          config = {
            home.stateVersion = "25.11";
            home.packages = [
              pkgs.git
              pkgs.sops
            ];
            home.file = {
              ".config/sops/age/keys.txt".source = "${fixtures}/${config.networking.hostName}.key";
              ".ssh/id_ed25519".source = "${fixtures}/ssh";
              "alice.json".source = "${fixtures}/alice.json";
              "bob.json".source = "${fixtures}/bob.json";
            };
            programs.ssh = {
              enable = true;
              enableDefaultConfig = false;
              settings."*" = {
                User = "operator";
                StrictHostKeyChecking = false;
                UserKnownHostsFile = "/dev/null";
                BatchMode = true;
                ConnectTimeout = 10;
              };
            };
          };
        };
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "sops-forwarding";
  nodes = {
    alice = node;
    bob = node;
  };
  testScript = ''
    import json
    import shlex

    def operator(machine, command):
        return machine.succeed("su - operator -c " + shlex.quote(command))

    start_all()
    for machine in (alice, bob):
        machine.wait_for_unit("sshd.service")
        machine.wait_for_unit("user@1000.service")
        operator(machine, "XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start sops-keyservice")
        machine.wait_until_succeeds("test -S /home/operator/.ssh/sops/local.sock")
        assert json.loads(operator(machine, f"sops decrypt {machine.name}.json")) == {"origin": machine.name}

    with subtest("native SSH and Git work without forwarding variables"):
        native_ssh = "${pkgs.openssh}/bin/ssh"
        operator(alice, f"{native_ssh} -G example.invalid >/dev/null")
        operator(alice, f"{native_ssh} -n bob 'test -z \"$SOPS_KEYSERVICE\"'")
        operator(bob, "git init --bare repository.git")
        operator(alice, f"GIT_SSH={native_ssh} git ls-remote bob:repository.git")

    with subtest("a session without a forwarded service can still use onward SSH"):
        onward = "ssh -n alice " + shlex.quote('test -z "$SOPS_KEYSERVICE" && echo connected')
        result = operator(alice, f"{native_ssh} -n bob {shlex.quote(onward)}")
        assert result.strip() == "connected"

    with subtest("an explicit SSH config overrides automatic forwarding"):
        operator(alice, "ssh -F /home/operator/.ssh/config -n bob 'test -z \"$SOPS_KEYSERVICE\"'")

    with subtest("each direction uses the originating operator identity"):
        for source, target in ((alice, "bob"), (bob, "alice")):
            result = operator(source, f"ssh -n {target} 'sops decrypt {source.name}.json'")
            assert json.loads(result) == {"origin": source.name}

    with subtest("onward SSH retains the first operator's identity"):
        result = operator(alice, "ssh -n bob \"ssh -n alice 'sops decrypt alice.json'\"")
        assert json.loads(result) == {"origin": "alice"}

    with subtest("concurrent sessions have independent endpoints"):
        operator(alice, "ssh -n bob 'printf %s \"$SOPS_KEYSERVICE\"; sleep 8' > /home/operator/first &")
        alice.wait_until_succeeds("test -s /home/operator/first")
        first = operator(alice, "cat /home/operator/first")
        second = operator(alice, "ssh -n bob 'printf %s \"$SOPS_KEYSERVICE\"'")
        assert first != second
        socket = first.removeprefix("unix://")
        result = operator(bob, f"SOPS_ENABLE_LOCAL_KEYSERVICE=false SOPS_KEYSERVICE={shlex.quote(first)} sops decrypt alice.json")
        assert json.loads(result) == {"origin": "alice"}
        bob.fail("su - nobody -s /bin/sh -c " + shlex.quote("test -r " + socket))
        # sshd may leave the socket pathname behind. What matters is that the
        # disconnected session can no longer use the originating key service.
        closed = f"SOPS_ENABLE_LOCAL_KEYSERVICE=false SOPS_KEYSERVICE={shlex.quote(first)} timeout 3 sops decrypt alice.json"
        bob.wait_until_succeeds("! su - operator -c " + shlex.quote(closed), timeout=20)

    with subtest("an unavailable origin never falls back to the destination's key"):
        operator(alice, "XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop sops-keyservice")
        alice.fail("su - operator -c \"ssh -n bob 'sops decrypt bob.json'\"")
  '';
}
