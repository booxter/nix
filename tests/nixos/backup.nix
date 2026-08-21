{ inputs, pkgs, ... }:
let
  fixtures = ./backup;
  secret = name: value: pkgs.writeText "backup-test-${name}" "${value}\n";
  password = secret "password" "test-password";
  clientPrivateKey = pkgs.writeText "backup-test-client-key" (
    builtins.readFile (fixtures + "/client-key")
  );
  s3AccessKey = "GKaaaaaaaaaaaaaaaaaaaaaaaa";
  s3SecretKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
in
pkgs.testers.runNixOSTest {
  name = "backup";

  defaults =
    { lib, nodes, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../nixos/_mixins/backups/composition.nix
        ./lib/sops.nix
      ];

      _module.args.backupConfigurations = lib.mapAttrs (
        _: node: builtins.removeAttrs node [ "config" ]
      ) nodes;
    };

  nodes = {
    server = {
      virtualisation.diskSize = 2 * 1024;

      environment.etc = {
        "ssh/ssh_host_ed25519_key" = {
          source = fixtures + "/server-key";
          mode = "0600";
        };
        "ssh/ssh_host_ed25519_key.pub".source = fixtures + "/server-key.pub";
      };

      services = {
        garage = {
          enable = true;
          package = pkgs.garage_2;
          settings = {
            rpc_bind_addr = "127.0.0.1:3901";
            rpc_public_addr = "127.0.0.1:3901";
            rpc_secret = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
            replication_factor = 1;
            s3_api = {
              s3_region = "us-east-1";
              api_bind_addr = "127.0.0.1:9000";
            };
          };
        };
        openssh = {
          hostKeys = [
            {
              path = "/etc/ssh/ssh_host_ed25519_key";
              type = "ed25519";
            }
          ];
          settings.PasswordAuthentication = false;
        };
      };

      host.backups.server = {
        repositoryRoot = "/srv/restic";
        offsite = {
          backend = "s3";
          endpoint = "http://127.0.0.1:9000";
          bucket = "backups";
        };
      };

      testSupport.sops.sources = {
        "backup/restic/client/cloud/localPassword" = password;
        "backup/restic/client/cloud/password" = password;
        "backup/restic/cloud/b2/applicationKeyId" = secret "s3-access-key" s3AccessKey;
        "backup/restic/cloud/b2/applicationKey" = secret "s3-secret-key" s3SecretKey;
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
        programs.ssh.knownHosts.server = {
          hostNames = [ "server" ];
          publicKeyFile = fixtures + "/server-key.pub";
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

        host.backups = {
          destination = {
            server = "server";
            publicKey = builtins.readFile (fixtures + "/client-key.pub");
          };
          sources.test = {
            title = "Backup Test";
            preparation = {
              service = "prepare-backup-test";
              paths = [ "/var/lib/backup-test/staged" ];
            };
          };
        };

        testSupport.sops.sources = {
          "backup/restic/local/password" = password;
          "backup/restic/local/ssh/privateKey" = clientPrivateKey;
        };
      };
  };

  testScript = ''
    CLOUD_REPOSITORY = "s3:http://127.0.0.1:9000/backups/client"
    S3_ACCESS_KEY = ${builtins.toJSON s3AccessKey}
    S3_SECRET_KEY = ${builtins.toJSON s3SecretKey}
  ''
  + builtins.readFile "${fixtures}/test.py";
}
