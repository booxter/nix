{
  config,
  facts,
  hostSpec,
  isDarwin,
  lib,
  pkgs,
  ...
}:
let
  realm = facts.realms.${config.host.realm};
  hostname = config.networking.hostName;
  username = config.host.username;
  userHome = if isDarwin then "/Users/${username}" else "/home/${username}";
  secrets = config.host.security.secrets;
  operatorIdentity = secrets.operator.ageIdentity;
  hasYubiAgeIdentity = builtins.elem hostname facts.yubi.ageIdentity.hosts;
  usesSecureEnclave = operatorIdentity != null && operatorIdentity.backend == "secure-enclave";
  usesYubiKey = operatorIdentity != null && operatorIdentity.backend == "yubikey";
in
{
  options.host.security = {
    secrets = {
      manageLocalPasswords = lib.mkOption {
        type = lib.types.bool;
        default = realm.management.managePasswordSecrets;
        readOnly = true;
        internal = true;
        description = "Whether local account passwords are managed through SOPS.";
      };

      operator = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = hostSpec.isSecretsOperator or false;
          readOnly = true;
          internal = true;
          description = "Whether this host manages repository secrets.";
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
          default =
            if hasYubiAgeIdentity then
              {
                backend = "yubikey";
                path = "${userHome}/.config/sops/age/${facts.yubi.ageIdentity.identityFileName}";
              }
            else
              null;
          defaultText = lib.literalExpression "YubiKey identity facts for this host, or null";
          description = "Hardware-backed age identity used for interactive repository secret operations.";
        };
      };
    };

    sudo.wheelNeedsPassword = lib.mkOption {
      type = lib.types.bool;
      default = realm.management.sudoWheelNeedsPassword;
      readOnly = true;
      internal = true;
      description = "Whether wheel users must enter a password for sudo.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !secrets.operator.enable || operatorIdentity != null;
          message = "Secrets operator ${hostname} must declare a hardware-backed age identity.";
        }
        {
          assertion = operatorIdentity == null || secrets.operator.enable;
          message = "Only secrets operators may declare host.security.secrets.operator.ageIdentity.";
        }
        {
          assertion = !usesSecureEnclave || (config.host.isDarwin && config.host.hardware.hasTouchId);
          message = "Secure Enclave age identities require a Darwin host with Touch ID.";
        }
        {
          assertion = !usesYubiKey || hasYubiAgeIdentity;
          message = "YubiKey age identities must be assigned to the host in YubiKey facts.";
        }
        {
          assertion = operatorIdentity == null || lib.hasPrefix "/" operatorIdentity.path;
          message = "host.security.secrets.operator.ageIdentity.path must be absolute.";
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
    (lib.mkIf (operatorIdentity != null) {
      home-manager.users.${username}.home.sessionVariables.SOPS_AGE_KEY_FILE = operatorIdentity.path;
    })
  ];
}
