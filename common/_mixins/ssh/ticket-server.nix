{
  config,
  facts,
  isDarwin,
  isLinux,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  target = facts.ssh-ticket.targetsByName.${config.networking.hostName};
  principal = "${username}@${target.name}";
  caPublicKeyTarget = "ssh/fleet-user-cas.pub";
  caPublicKeyPath = "/etc/${caPublicKeyTarget}";
  principalsTarget = "ssh/authorized_principals.d/${username}";
  principalsPath = "/etc/ssh/authorized_principals.d/%u";
  caPublicKeyFile = pkgs.writeText "fleet-user-cas.pub" (
    lib.concatMapStrings (publicKey: "${publicKey}\n") target.trustedCaPublicKeys
  );
  principalsFile = pkgs.writeText "${username}-authorized_principals" "${principal}\n";
in
{
  config = lib.mkMerge [
    {
      environment.etc.${caPublicKeyTarget} = lib.mkIf target.enabled (
        {
          source = caPublicKeyFile;
        }
        // lib.optionalAttrs isDarwin {
          mode = "0444";
          user = "root";
          group = "wheel";
        }
      );
    }
    (lib.optionalAttrs isLinux {
      services.openssh.settings.TrustedUserCAKeys = lib.mkIf target.enabled caPublicKeyPath;
      users.users.${username}.openssh.authorizedPrincipals = lib.mkIf target.enabled [
        principal
      ];
    })
    (lib.optionalAttrs isDarwin {
      environment.etc.${principalsTarget} = lib.mkIf target.enabled {
        source = principalsFile;
        mode = "0444";
        user = "root";
        group = "wheel";
      };

      services.openssh.extraConfig = lib.mkIf target.enabled ''
        TrustedUserCAKeys ${caPublicKeyPath}
        AuthorizedPrincipalsFile ${principalsPath}
      '';
    })
  ];
}
