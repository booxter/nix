{
  config,
  lib,
  pkgs,
  system,
  ...
}:
let
  inherit (lib.systems.elaborate system) isDarwin isLinux;
  username = config.host.username;
  tickets = config.host.ssh.tickets;
  enabled = tickets.trustedCaPublicKeys != [ ];
  principal = "${username}@${config.networking.hostName}";
  caPublicKeyTarget = "ssh/fleet-user-cas.pub";
  caPublicKeyPath = "/etc/${caPublicKeyTarget}";
  principalsTarget = "ssh/authorized_principals.d/${username}";
  principalsPath = "/etc/ssh/authorized_principals.d/%u";
  caPublicKeyFile = pkgs.writeText "fleet-user-cas.pub" (
    lib.concatMapStrings (publicKey: "${publicKey}\n") tickets.trustedCaPublicKeys
  );
  principalsFile = pkgs.writeText "${username}-authorized_principals" "${principal}\n";
in
{
  config = lib.mkMerge [
    {
      environment.etc.${caPublicKeyTarget} = lib.mkIf enabled (
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
      services.openssh.settings.TrustedUserCAKeys = lib.mkIf enabled caPublicKeyPath;
      users.users.${username}.openssh.authorizedPrincipals = lib.mkIf enabled [
        principal
      ];
    })
    (lib.optionalAttrs isDarwin {
      environment.etc.${principalsTarget} = lib.mkIf enabled {
        source = principalsFile;
        mode = "0444";
        user = "root";
        group = "wheel";
      };

      services.openssh.extraConfig = lib.mkIf enabled ''
        TrustedUserCAKeys ${caPublicKeyPath}
        AuthorizedPrincipalsFile ${principalsPath}
      '';
    })
  ];
}
