{ pkgs, ... }:
let
  inherit (pkgs) lib;
  keys = pkgs.runCommand "sudo-agent-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p "$out"
    ssh-keygen -q -t ecdsa -b 256 -N "" -f "$out/approved"
    ssh-keygen -q -t ed25519 -N "" -f "$out/unapproved"
  '';
in
pkgs.testers.runNixOSTest {
  name = "sudo-agent";

  nodes = {
    client = {
      environment.systemPackages = [ pkgs.openssh ];
    };
    server = {
      imports = [
        ../../common/_mixins/security/sudo.nix
        ../../nixos/_mixins/security/sudo.nix
      ];
      options.host.username = lib.mkOption {
        type = lib.types.str;
        default = "operator";
      };
      options.host.realm = lib.mkOption {
        type = lib.types.str;
        default = "home";
      };
      config = {
        _module.args.sshKeys.sudo = {
          home = [ (lib.removeSuffix "\n" (builtins.readFile "${keys}/approved.pub")) ];
          work = [ (lib.removeSuffix "\n" (builtins.readFile "${keys}/unapproved.pub")) ];
        };
        users.users.operator = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          initialPassword = "test-password";
          openssh.authorizedKeys.keyFiles = [
            "${keys}/approved.pub"
            "${keys}/unapproved.pub"
          ];
        };
        services.openssh.enable = true;
      };
    };
  };

  testScript = ''
    start_all()
    server.wait_for_unit("sshd.service")
    server.wait_for_open_port(22)
    client.wait_for_unit("multi-user.target")
    client.succeed("mkdir -p /root/.ssh; cp ${keys}/* /root/.ssh/; chmod 600 /root/.ssh/*")
    client.succeed("ssh-agent -a /root/agent")

    # SSH must not consume the test driver's shell protocol from stdin.
    ssh = "ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /root/.ssh/approved"
    agent = "SSH_AUTH_SOCK=/root/agent "
    sudo = "sudo -k -n id -u"

    with subtest("a forwarded authorized agent authenticates sudo"):
        client.succeed(agent + "ssh-add /root/.ssh/approved")
        assert client.succeed(agent + ssh + " -A operator@server '" + sudo + "'").strip() == "0"

    with subtest("approval is shared across SSH sessions until revoked"):
        assert client.succeed(agent + ssh + " -A operator@server 'sudo -K; sudo -n id -u'").strip() == "0"
        assert client.succeed(agent + ssh + " -a operator@server 'sudo -n id -u'").strip() == "0"
        client.fail(agent + ssh + " -a operator@server 'sudo -K; sudo -n id -u'")

    with subtest("SSH login alone does not authorize sudo"):
        client.fail(agent + ssh + " -a operator@server '" + sudo + "'")

    with subtest("another realm's sudo key is rejected even when authorized for SSH"):
        client.succeed(agent + "ssh-add -D")
        client.succeed(agent + "ssh-add /root/.ssh/unapproved")
        client.fail(agent + ssh + " -A operator@server '" + sudo + "'")

    with subtest("the operator cannot change the sudo key allowlist"):
        server.fail("su - operator -c 'echo invalid >> /etc/sudo/authorized_keys/operator'")

    with subtest("password authentication remains available without an agent"):
        output = server.succeed("su - operator -c 'printf \"test-password\\n\" | sudo -k -S id -u'")
        assert output.strip() == "0"
  '';
}
