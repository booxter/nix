{ pkgs, ... }:
let
  clientPrivateKey = ''
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCVNmQc9v2Mk7UahzgJfb/dKhMl+J7SyjHtDsWYwsij2AAAAKCijFNNooxT
    TQAAAAtzc2gtZWQyNTUxOQAAACCVNmQc9v2Mk7UahzgJfb/dKhMl+J7SyjHtDsWYwsij2A
    AAAEA9dT2RtGIcZ9CUUaHp8ldV46mo87CpfX5vx8CKUtp9f5U2ZBz2/YyTtRqHOAl9v90q
    EyX4ntLKMe0OxZjCyKPYAAAAFmlocmFjaHlzaGthQEpHV1hIV0RMNFgBAgMEBQYH
    -----END OPENSSH PRIVATE KEY-----
  '';
  clientPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJU2ZBz2/YyTtRqHOAl9v90qEyX4ntLKMe0OxZjCyKPY backup-test-client";
  serverPrivateKey = ''
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACB6n/zaSVqpqbX3o50yYYe8I4T8qD5a7iNJNM+ukUyT2wAAAKAD1dIjA9XS
    IwAAAAtzc2gtZWQyNTUxOQAAACB6n/zaSVqpqbX3o50yYYe8I4T8qD5a7iNJNM+ukUyT2w
    AAAEArc0YV+SEIunxiYtCkqlAFI9QI3/C0A8Oi2g5ThZ6smXqf/NpJWqmptfejnTJhh7wj
    hPyoPlruI0k0z66RTJPbAAAAFmlocmFjaHlzaGthQEpHV1hIV0RMNFgBAgMEBQYH
    -----END OPENSSH PRIVATE KEY-----
  '';
  serverPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqf/NpJWqmptfejnTJhh7wjhPyoPlruI0k0z66RTJPb backup-test-server";
in
pkgs.testers.runNixOSTest {
  name = "backup";

  nodes = {
    server = {
      imports = [ ../../nixos/_mixins/backups ];

      networking.firewall.allowedTCPPorts = [ 22 ];

      environment.etc = {
        "ssh/ssh_host_ed25519_key" = {
          text = serverPrivateKey;
          mode = "0600";
        };
        "ssh/ssh_host_ed25519_key.pub".text = serverPublicKey;
      };

      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        settings.PasswordAuthentication = false;
      };

      host.backups.server = {
        enable = true;
        repositoryRoot = "/srv/restic";
        clients.test.publicKey = clientPublicKey;
      };
    };

    client =
      { lib, ... }:
      let
        preparation = pkgs.writeShellApplication {
          name = "prepare-backup-test";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            if test -e /run/fail-backup-preparation; then
              exit 1
            fi
            install -d -m 0750 /var/lib/backup-test/staged
            count=0
            if test -e /var/lib/backup-test/preparation-count; then
              count=$(< /var/lib/backup-test/preparation-count)
            fi
            printf '%s\n' "$((count + 1))" > /var/lib/backup-test/preparation-count
            cp /var/lib/backup-test/source.txt /var/lib/backup-test/staged/source.txt
          '';
        };
      in
      {
        imports = [ ../../nixos/_mixins/backups ];

        environment.etc = {
          "backup-test/id_ed25519" = {
            text = clientPrivateKey;
            mode = "0400";
          };
          "backup-test/password" = {
            text = "test-password\n";
            mode = "0400";
          };
        };

        programs.ssh.knownHosts.server = {
          hostNames = [ "server" ];
          publicKey = serverPublicKey;
        };

        systemd.services.prepare-backup-test = {
          description = "Prepare the backup test artifact";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe preparation;
          };
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/backup-test 0750 root root -"
        ];

        host.backups.jobs.test = {
          title = "Backup Test";
          repository = {
            type = "sftp";
            path = "/srv/restic/test";
            passwordFile = "/etc/backup-test/password";
            sftp = {
              host = "server";
              user = "restic-test";
              identityFile = "/etc/backup-test/id_ed25519";
            };
          };
          preparations.prepare-backup-test = {
            title = "Prepare Backup Test";
            paths = [ "/var/lib/backup-test/staged" ];
          };
          timerConfig.OnCalendar = "2099-01-01";
        };
      };
  };

  testScript = ''
    import json


    def snapshot_count():
        return len(json.loads(client.succeed("restic-test snapshots --json")))


    def assert_metric(file_name, metric, value):
        metrics = client.succeed(f"cat /var/lib/prometheus-node-exporter-textfile/{file_name}")
        matches = [line for line in metrics.splitlines() if line.startswith(metric + "{")]
        assert len(matches) == 1, (metric, metrics)
        assert matches[0].endswith(f" {value}"), matches[0]


    start_all()
    server.wait_for_unit("sshd.service")
    client.wait_for_unit("multi-user.target")
    client.wait_for_unit("backup-metrics-configured.service")
    client.succeed("printf 'first version\\n' > /var/lib/backup-test/source.txt")

    with subtest("only the complete pipeline has a timer"):
        client.succeed("systemctl cat restic-backups-test.timer")
        client.fail("systemctl cat prepare-backup-test.timer")

    with subtest("pipeline prepares and snapshots once"):
        client.succeed("systemctl start restic-backups-test.service")
        assert client.succeed("cat /var/lib/backup-test/preparation-count").strip() == "1"
        assert snapshot_count() == 1
        assert_metric("prepare-backup-test.prom", "host_observability_backup_last_success", "1.0")
        assert_metric("restic-test.prom", "host_observability_backup_last_success", "1.0")

    with subtest("snapshot restores the prepared content"):
        client.succeed("rm -rf /tmp/restore")
        client.succeed("restic-test restore latest --target /tmp/restore")
        restored = client.succeed("cat /tmp/restore/var/lib/backup-test/staged/source.txt")
        assert restored.strip() == "first version", restored

    with subtest("failed preparation blocks a new snapshot"):
        client.succeed("touch /run/fail-backup-preparation")
        client.fail("systemctl start restic-backups-test.service")
        assert snapshot_count() == 1
        assert_metric("prepare-backup-test.prom", "host_observability_backup_last_success", "0.0")

    with subtest("SFTP account cannot execute commands"):
        client.fail("ssh restic-test@restic-backup-test true")
  '';
}
