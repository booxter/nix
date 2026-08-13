{ pkgs, ... }:
let
  inherit (pkgs) lib;
  pin = (import ../../facts/oci-images/facts.nix).pinepods;
  testFacts.oci-images.pinepods = pin // {
    ref = "${pin.image}:${pin.tag}";
  };
  testOutputs.nixosConfigurations = { };
  secretType =
    { name, ... }:
    {
      options = {
        path = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/${name}";
        };
        owner = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
        };
        restartUnits = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
        };
      };
    };
  templateType =
    { name, ... }:
    {
      options = {
        path = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets-rendered/${name}";
        };
        content = lib.mkOption { type = lib.types.lines; };
        owner = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
        };
        restartUnits = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
        };
      };
    };
  supportModule =
    { config, lib, ... }:
    {
      options = {
        host = {
          accounts = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          backups.sources = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          site.timeZone = lib.mkOption {
            type = lib.types.str;
            default = "Etc/UTC";
          };
          sso = {
            applications = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            users = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            oidc = {
              baseScopes = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
              };
              clients = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
            };
          };
          storage = {
            claims = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            resources = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            volumes = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
          web.services = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
        };
        sops = {
          secrets = lib.mkOption {
            type = with lib.types; attrsOf (submodule secretType);
            default = { };
          };
          templates = lib.mkOption {
            type = with lib.types; attrsOf (submodule templateType);
            default = { };
          };
          placeholder = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
        };
      };

      config = {
        systemd.services.sops-install-secrets = {
          description = "Install PinePods integration-test secrets";
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            ${lib.concatMapStringsSep "\n" (secret: ''
              install -D -m ${secret.mode} -o ${secret.owner} -g ${secret.group} /dev/null ${lib.escapeShellArg secret.path}
            '') (builtins.attrValues config.sops.secrets)}
            printf '%s\n' 'database-password' > ${config.sops.secrets."pinepods/postgresql/password".path}
            printf '%s\n' 'cache-password' > ${config.sops.secrets."pinepods/valkey/password".path}
            printf '%s\n' 'test-password' > ${config.sops.secrets."pinepods/bootstrap/password".path}
            printf '%s\n' 'owner@example.invalid' > ${config.sops.secrets."directory/users/owner/mail".path}
            printf '%s\n' 'oidc-secret' > ${config.sops.secrets."pinepods/oidc/client_secret".path}
            ${lib.concatMapStringsSep "\n" (name: ''
              install -D -m ${config.sops.templates.${name}.mode} -o ${config.sops.templates.${name}.owner} -g ${
                config.sops.templates.${name}.group
              } /dev/null ${lib.escapeShellArg config.sops.templates.${name}.path}
              cat > ${config.sops.templates.${name}.path} <<'EOF'
              ${config.sops.templates.${name}.content}
              EOF
            '') (builtins.attrNames config.sops.templates)}
          '';
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "pinepods";

  nodes.machine =
    { ... }:
    {
      imports = [
        supportModule
        ../../nixos/_mixins/pinepods
      ];

      _module.args = {
        facts = testFacts;
        outputs = testOutputs;
      };

      networking.hostName = "podcast-node";

      host = {
        accounts.users.pinepods.uid = 911;
        pinepods = {
          enable = true;
          publicHostName = "podcasts.example.invalid";
          storage = {
            claim = "podcasts";
            relativePath = "downloads/pinepods";
          };
          sso.application = "podcast-listeners";
          integrations = {
            searchApi.url = "https://search.example.invalid/api/search";
            podPeople.url = "https://people.example.invalid";
          };
        };
        storage = {
          claims.podcasts = {
            provider = "podcast-node";
            resource = "podcasts";
            mountPoint = "/srv/podcasts";
          };
          resources.podcasts = {
            volume = "durable";
            relativePath = ".";
            sharedGroup = "podcasts";
            directoryDefaults = {
              owner = "root";
              group = "podcasts";
              mode = "0755";
              enforce = false;
            };
          };
          volumes.durable.mountPoint = "/srv/durable";
        };
        sso = {
          applications.podcast-listeners = {
            adminGroup = "podcast-admins";
            userGroup = "podcast-users";
            bootstrapOwner = "owner";
          };
          users.owner = {
            displayName = "Test Owner";
            mailAddressSopsKey = "directory/users/owner/mail";
            groups = [
              "podcast-admins"
              "podcast-users"
            ];
          };
          oidc = {
            baseScopes = [
              "openid"
              "email"
              "profile"
            ];
            clients.pinepods = {
              clientId = "pinepods";
              authorizationUrl = "https://login.example.invalid/ui/oauth2";
              tokenUrl = "https://login.example.invalid/oauth2/token";
              userinfoUrl = "https://login.example.invalid/oauth2/openid/pinepods/userinfo";
              secret.placeholder = "oidc-secret";
            };
          };
        };
        web.services.pinepods.public.url = "https://podcasts.example.invalid";
      };

      sops.placeholder = {
        "pinepods/postgresql/password" = "database-password";
        "pinepods/valkey/password" = "cache-password";
      };
      sops.secrets."pinepods/oidc/client_secret" = { };

      users.groups.podcasts.gid = 911;
      systemd.tmpfiles.rules = [
        "d /srv/podcasts 0755 root root - -"
        "d /srv/podcasts/downloads/pinepods 0750 pinepods podcasts - -"
      ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("pinepods-valkey.service")
    machine.wait_for_unit("podman-pinepods.service")
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:8040/api/health | ${lib.getExe pkgs.jq} -e '.database and .redis'")
    machine.wait_for_unit("pinepods-bootstrap-admin.service")
    machine.succeed(
        "curl -sf http://127.0.0.1:8040/api/data/self_service_status"
        " | ${lib.getExe pkgs.jq} -e '.first_admin_created == true'"
    )
    machine.succeed("runuser -u pinepods -- test -w /srv/podcasts/downloads/pinepods")
  '';
}
