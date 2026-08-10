{
  config,
  facts,
  isDarwin,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  userHome = if isDarwin then "/Users/${username}" else "/home/${username}";
  operatorIdentity = config.host.secrets.operatorAgeIdentity;
  usesSecureEnclave = operatorIdentity != null && operatorIdentity.backend == "secure-enclave";
in
{
  imports = [ ./assertions.nix ];

  options.host.secrets.operatorAgeIdentity = lib.mkOption {
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
      if config.host.hasYubiAgeIdentity then
        {
          backend = "yubikey";
          path = "${userHome}/.config/sops/age/${facts.yubi.ageIdentity.identityFileName}";
        }
      else
        null;
    defaultText = lib.literalExpression "YubiKey identity facts for this host, or null";
    description = "Hardware-backed age identity used for interactive repository secret operations.";
  };

  config = lib.mkMerge [
    {
      sops.age.keyFile = "/var/lib/sops-nix/key.txt";
      sops.defaultSopsFile =
        ../../../secrets + "/${config.host.realm}/${config.networking.hostName}.yaml";
    }
    (lib.mkIf config.host.isSecretsOperator {
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
