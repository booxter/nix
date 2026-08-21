{ inputs, pkgs, ... }:
let
  fixtures = ./pinepods;
  inherit (pkgs) lib;
  secret = name: value: pkgs.writeText "pinepods-test-${name}" "${value}\n";
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

    networking.hostName = "podcast-node";

    host = {
      realm = "test";
      pinepods = { };
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

    testSupport.sops.sources = {
      "pinepods/postgresql/password" = secret "database-password" "database-password";
      "pinepods/valkey/password" = secret "cache-password" "cache-password";
      "pinepods/bootstrap/password" = secret "bootstrap-password" "test-password";
      "directory/users/owner/mail" = secret "owner-mail" "owner@example.invalid";
      "pinepods/oidc/client_secret" = secret "oidc-secret" "oidc-secret";
    };

    # The VM provides the storage claim as an already-mounted test fixture.
    systemd.tmpfiles.rules = [
      "d /srv/podcasts/podcasts/pinepods 0750 pinepods media - -"
    ];
  };

  testScript = ''
    JQ = ${builtins.toJSON (lib.getExe pkgs.jq)}
  ''
  + builtins.readFile "${fixtures}/test.py";
}
