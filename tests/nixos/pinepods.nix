{ inputs, pkgs, ... }:
let
  fixtures = ./pinepods;
  inherit (pkgs) lib;
  testPki = import ./lib/tls-pki.nix {
    inherit pkgs;
    serverName = "ollama";
    clientName = "pinepods.podcast-node";
  };
in
pkgs.testers.runNixOSTest {
  name = "pinepods";

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/pinepods/composition.nix
      ./lib/sops.nix
    ];

    _module.args.storageConfigurations = { };
    _module.args.outputs.nixosConfigurations.ollama.config.host = {
      realm = "test";
      ollama.models."test-model" = { };
      web.services.ollama.internal.serverName = "ollama";
    };

    virtualisation = {
      memorySize = 4096;
      # Podman unpacks both images into the VM's writable root filesystem.
      diskSize = 8192;
    };

    networking.hostName = "podcast-node";

    host = {
      realm = "test";
      pinepods = {
        ollamaHost = "ollama";
        adDetectionModel = "test-model";
      };
      pki.authority = {
        hostName = "ollama";
        rootCaCertificate = "${testPki}/ca.crt";
      };
      network.publicDomain = "example.invalid";
      site.timeZone = "Etc/UTC";
      storage = {
        claims.media = {
          provider = "podcast-node";
          resource = "media";
          mountPoint = "/srv/podcasts";
        };
        resources.media = {
          volume = "durable";
          relativePath = ".";
          directoryDefaults = {
            owner = "root";
            group = "media";
            mode = "0755";
          };
        };
        volumes.durable = {
          mountPoint = "/srv/durable";
          device = "none";
          fsType = "tmpfs";
        };
      };
      sso = {
        providerHost = "identity";
        groups = [
          "podcast-admins"
          "podcast-users"
        ];
        applications.pinepods = {
          roles = {
            admin = "podcast-admins";
            user = "podcast-users";
          };
          bootstrapOwner = "owner";
        };
        users.owner = {
          mailAddressSopsKey = "directory/users/owner/mail";
          groups = [
            "podcast-admins"
            "podcast-users"
          ];
        };
      };
      web.services.pinepods.public.hostName = "pod.example.invalid";
    };

    sops.placeholder = {
      "pinepods/postgresql/password" = "database-password";
      "pinepods/valkey/password" = "cache-password";
      "pinepods/oidc/client_secret" = "oidc-secret";
    };

    testSupport.sops.values = {
      "pinepods/postgresql/password" = "database-password";
      "pinepods/valkey/password" = "cache-password";
      "pinepods/bootstrap/password" = "test-password";
      "directory/users/owner/mail" = "owner@example.invalid";
      "pinepods/oidc/client_secret" = "oidc-secret";
    };
    testSupport.sops.sources = {
      internal-pki-client-pinepods-ollama-crt = "${testPki}/client.crt";
      internal-pki-client-pinepods-ollama-key = "${testPki}/client.key";
    };

    # The VM provides the storage claim as an already-mounted test fixture.
    systemd.tmpfiles.rules = [
      "d /srv/podcasts/podcasts/pinepods 0750 pinepods media - -"
    ];
  };

  # A real mTLS endpoint supplies model discovery without downloading an LLM.
  nodes.ollama = {
    networking.firewall.allowedTCPPorts = [ 443 ];
    services.nginx = {
      enable = true;
      virtualHosts.ollama = {
        forceSSL = true;
        sslCertificate = "${testPki}/server.crt";
        sslCertificateKey = "${testPki}/server.key";
        extraConfig = ''
          ssl_client_certificate ${testPki}/ca.crt;
          ssl_verify_client on;
        '';
        locations."/api/tags".return = "200 '${
          builtins.toJSON { models = [ { name = "test-model"; } ]; }
        }'";
      };
    };
  };

  testScript = ''
    JQ = ${builtins.toJSON (lib.getExe pkgs.jq)}
  ''
  + builtins.readFile (fixtures + "/test.py");
}
