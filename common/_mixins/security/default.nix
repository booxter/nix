{
  config,
  fleetInventory,
  lib,
  pkgs,
  ...
}:
let
  operatorIdentity = config.host.security.secrets.operator.ageIdentity;
  usesSecureEnclave = operatorIdentity != null && operatorIdentity.backend == "secure-enclave";
  realmsByHost = lib.mapAttrs (_: host: host.realm) fleetInventory.hosts;
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
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            !usesSecureEnclave || (config.nixpkgs.hostPlatform.isDarwin && config.host.hardware.hasTouchId);
          message = "Secure Enclave age identities require a Darwin host with Touch ID.";
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
