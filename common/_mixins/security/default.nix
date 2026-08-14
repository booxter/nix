{
  config,
  lib,
  outputs,
  pkgs,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  operatorIdentity = config.host.security.secrets.operator.ageIdentity;
  usesSecureEnclave = operatorIdentity != null && operatorIdentity.backend == "secure-enclave";
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  realmsByHost = lib.mapAttrs (_: configuration: configuration.config.host.realm) configurations;
  sopsTools = import ../../../apps/sops/package.nix { inherit pkgs realmsByHost; };
in
{
  options.host.security = {
    secrets = {
      operator = {
        ageIdentity = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                backend = lib.mkOption {
                  type = lib.types.enum [
                    "secure-enclave"
                    "yubikey"
                  ];
                  description = "Hardware backend holding the operator age identity.";
                };

                path = lib.mkOption {
                  type = lib.types.strMatching "^/.+";
                  description = "Absolute path to the age identity file or hardware identity handle.";
                };
              };
            }
          );
          default = null;
          description = "Hardware-backed age identity used for interactive repository secret operations.";
        };
      };
    };

    ssh.credentials = {
      backend = lib.mkOption {
        type = lib.types.enum [
          "files"
          "secretive"
          "yubikey"
        ];
        default = "files";
        description = "Backend providing the operator's SSH authentication and signing identity.";
      };

      secretive.publicKey = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Public signing key managed by Secretive.";
      };

    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            !usesSecureEnclave || (config.nixpkgs.hostPlatform.isDarwin && config.host.hardware.hasTouchId);
          message = "Secure Enclave age identities require a Darwin host with Touch ID.";
        }
        {
          assertion = config.host.security.ssh.credentials.backend != "secretive" || isDarwin;
          message = "Secretive SSH credentials require Darwin.";
        }
        {
          assertion =
            config.host.security.ssh.credentials.backend != "secretive"
            || config.host.security.ssh.credentials.secretive.publicKey != null;
          message = "Secretive SSH credentials require host.security.ssh.credentials.secretive.publicKey.";
        }
      ];

      sops.age.keyFile = "/var/lib/sops-nix/key.txt";
      sops.defaultSopsFile =
        ../../../secrets + "/${config.host.realm}/${config.networking.hostName}.yaml";
    }
    (lib.mkIf (operatorIdentity != null) {
      environment.systemPackages = [
        pkgs.age
        pkgs.sops
        sopsTools
      ]
      ++ lib.optional usesSecureEnclave pkgs.age-plugin-se;
    })
  ];
}
