{ inputs, pkgs, ... }:
let
  fixtures = ./romm;
  serverName = "romm.test.invalid";
  testPki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
in
pkgs.testers.runNixOSTest {
  name = "romm";
  globalTimeout = 15 * 60;
  node.specialArgs = { inherit inputs; };

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/romm/composition.nix
      ./lib/sops.nix
    ];

    _module.args = {
      backupTopology.client.destination = null;
      storageConfigurations = { };
    };

    networking.hostName = "romm-test";

    host = {
      realm = "test";
      network = {
        lanDomain = "test.invalid";
        publicDomain = "example.invalid";
      };
      romm.publicHostName = "games.example.invalid";
      pki.authority = {
        hostName = "romm-test";
        rootCaCertificate = "${testPki}/ca.crt";
      };
      storage = {
        claims.media = {
          provider = "romm-test";
          resource = "media";
          mountPoint = "/srv/media";
        };
        resources.media = {
          volume = "durable";
          relativePath = ".";
          directoryDefaults = {
            owner = "root";
            group = "media";
            mode = "0755";
            enforce = false;
          };
        };
        volumes.durable = {
          mountPoint = "/srv/durable";
          device = "none";
          fsType = "tmpfs";
        };
      };
      sso = {
        providerHost = "romm-test";
        groups = [
          "romm-admins"
          "romm-editors"
          "romm-viewers"
        ];
        applications.romm = {
          bootstrapOwner = "admin";
          roles = {
            admin = "romm-admins";
            editor = "romm-editors";
            viewer = "romm-viewers";
          };
        };
        users = {
          admin.groups = [ "romm-admins" ];
          editor.groups = [ "romm-editors" ];
          viewer.groups = [ "romm-viewers" ];
        };
      };
      web.services.romm = {
        internal = {
          inherit serverName;
          clientAuth = "none";
        };
        public.hostName = "games.example.invalid";
      };
    };

    # NixOS tests replace normal host filesystems with their VM root disk.
    # Recreate the local provider volume and its claim inside the VM.
    virtualisation = {
      cores = 2;
      diskSize = 8 * 1024;
      memorySize = 4 * 1024;
      fileSystems = {
        "/srv/durable" = {
          device = "none";
          fsType = "tmpfs";
        };
        "/srv/media" = {
          device = "/srv/durable";
          fsType = "none";
          options = [
            "bind"
            "nofail"
            "x-systemd.requires-mounts-for=/srv/durable"
          ];
        };
      };
    };

    sops.placeholder = {
      "romm/authSecretKey" = "test-auth-secret-key-with-enough-entropy";
      "romm/dbPassword" = "test-database-password";
      "romm/oidc/clientSecret" = "test-oidc-client-secret";
    };
    testSupport.sops = {
      sources = {
        internal-https-romm-server-crt = "${testPki}/server.crt";
        internal-https-romm-server-key = "${testPki}/server.key";
      };
      values = {
        "romm/authSecretKey" = "test-auth-secret-key-with-enough-entropy";
        "romm/dbPassword" = "test-database-password";
        "romm/oidc/clientSecret" = "test-oidc-client-secret";
      };
    };
  };

  testScript = ''
    CA_CERTIFICATE = ${builtins.toJSON "${testPki}/ca.crt"}
    CURL = ${builtins.toJSON (pkgs.lib.getExe pkgs.curl)}
    SERVER_NAME = ${builtins.toJSON serverName}
  ''
  + builtins.readFile "${fixtures}/test.py";
}
