{
  config,
  fleetInventory,
  lib,
  pkgs,
  ...
}:
let
  operatorIdentity = config.host.security.secrets.operator.ageIdentity;
  homeRealm = config.host.realm == "home";
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
      # TODO: remove
      # Block both trust paths to the compromised eMudhra intermediates.
      # https://emudhra.we-have-a-problem.com/
      security.pki.caCertificateBlacklist = [
        "Comodo AAA Services root"
      ]
      # NSS 3.131.1 removed these roots, and cacert fails the build when a
      # blocklisted name is missing. Keep them only for older bundles.
      # https://bugzilla.mozilla.org/show_bug.cgi?id=2083709
      # TODO: drop once nixpkgs-darwin ships NSS 3.131.1.
      ++ lib.optionals (lib.versionOlder pkgs.cacert.version "3.131.1") [
        "emSign ECC Root CA - G3"
        "emSign Root CA - C1"
        "emSign ECC Root CA - C3"
      ];

      assertions = [
        {
          assertion =
            !usesSecureEnclave || (config.nixpkgs.hostPlatform.isDarwin && config.host.hardware.hasTouchId);
          message = "Secure Enclave age identities require a Darwin host with Touch ID.";
        }
      ];

      sops.age = {
        keyFile = if homeRealm then null else "/var/lib/sops-nix/key.txt";
        sshKeyPaths = lib.optionals homeRealm [ "/etc/ssh/ssh_host_ed25519_key" ];
      };
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
