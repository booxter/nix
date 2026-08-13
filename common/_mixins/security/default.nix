{
  config,
  isDarwin,
  lib,
  pkgs,
  ...
}:
let
  secrets = config.host.security.secrets;
  operatorIdentity = secrets.operator.ageIdentity;
  usesSecureEnclave = operatorIdentity != null && operatorIdentity.backend == "secure-enclave";
in
{
  imports = [
    ./home.nix
    ./work.nix
  ];

  options.host.security = {
    sudo.wheelNeedsPassword = lib.mkOption {
      type = lib.types.bool;
      description = "Whether members of the wheel group must enter a password for sudo.";
    };

    secrets = {
      operator = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = operatorIdentity != null;
          readOnly = true;
          internal = true;
          description = "Whether this host manages repository secrets, derived from its operator identity.";
        };

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
                  type = lib.types.nonEmptyStr;
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
          assertion = !usesSecureEnclave || (config.host.isDarwin && config.host.hardware.hasTouchId);
          message = "Secure Enclave age identities require a Darwin host with Touch ID.";
        }
        {
          assertion = operatorIdentity == null || lib.hasPrefix "/" operatorIdentity.path;
          message = "host.security.secrets.operator.ageIdentity.path must be absolute.";
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
    (lib.mkIf secrets.operator.enable {
      environment.systemPackages =
        with pkgs;
        [
          age
          sops
          sops-tools
        ]
        ++ lib.optional usesSecureEnclave age-plugin-se;
    })
  ];
}
