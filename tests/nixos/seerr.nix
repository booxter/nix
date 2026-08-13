{ pkgs, ... }:
let
  inherit (pkgs) lib;
  secretType =
    { name, ... }:
    {
      options = {
        path = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/${name}";
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
    { config, ... }:
    {
      options = {
        host = {
          backups.sources = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          media.libraries = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          storage.claims = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          web = {
            api = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            services = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
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

      config.systemd.services.sops-install-secrets = {
        description = "Install Seerr integration-test secrets";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${lib.concatMapStringsSep "\n" (secret: ''
            install -D -m 0400 /dev/null ${lib.escapeShellArg secret.path}
            printf '%s' 'integration-test-secret' > ${lib.escapeShellArg secret.path}
          '') (builtins.attrValues config.sops.secrets)}
          ${lib.concatMapStringsSep "\n" (name: ''
            install -D -m ${config.sops.templates.${name}.mode} \
              -o ${config.sops.templates.${name}.owner} \
              -g ${config.sops.templates.${name}.group} \
              /dev/null ${lib.escapeShellArg config.sops.templates.${name}.path}
            cat > ${lib.escapeShellArg config.sops.templates.${name}.path} <<'EOF'
            ${config.sops.templates.${name}.content}
            EOF
          '') (builtins.attrNames config.sops.templates)}
        '';
      };
    };
  testOutputs.nixosConfigurations.media-provider.config.host.jellyfin = {
    enable = true;
    publicUrl = "https://media.example.invalid";
    libraries = {
      cinema.name = "Cinema";
      television.name = "Television";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "seerr";

  nodes.machine = {
    imports = [
      supportModule
      ../../nixos/_mixins/seerr
    ];

    _module.args.outputs = testOutputs;
    networking.hostName = "request-node";

    host.seerr = {
      enable = true;
      publicHostName = "requests.example.invalid";
      integrations.jellyfin = {
        host = "media-provider";
        libraries = [
          "cinema"
          "television"
        ];
      };
    };
    host.web.services.seerr.public.url = "https://requests.example.invalid";

    sops.placeholder."seerr/api_key" = "integration-test-secret";

    # Fresh Seerr requires its first Jellyfin administrator login before the
    # settings reconciler can run. Exercise the real module and service here;
    # package tests cover reconciliation behavior before that bootstrap seam.
    systemd.services.seerr-reconcile.wantedBy = lib.mkForce [ ];
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("seerr.service")
    machine.wait_for_open_port(5055)
    machine.succeed(
        "curl -sf http://127.0.0.1:5055/api/v1/settings/public"
        " | ${lib.getExe pkgs.jq} -e '.initialized == false'"
    )
    machine.succeed("test $(stat -c %a /run/secrets-rendered/seerr-environment) = 400")
    machine.succeed("grep -Fx 'API_KEY=integration-test-secret' /run/secrets-rendered/seerr-environment")
    machine.succeed("test $(stat -c %U /var/lib/seerr) = seerr")
  '';
}
