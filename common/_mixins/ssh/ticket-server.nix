{
  config,
  lib,
  pkgs,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
  username = config.host.username;
  tickets = config.host.ssh.tickets;
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
      environment.etc.${caPublicKeyTarget} = lib.mkIf tickets.enable (
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
      services.openssh.settings.TrustedUserCAKeys = lib.mkIf tickets.enable caPublicKeyPath;
      users.users.${username}.openssh.authorizedPrincipals = lib.mkIf tickets.enable [
        principal
      ];
    })
    (lib.optionalAttrs isDarwin {
      environment.etc.${principalsTarget} = lib.mkIf tickets.enable {
        source = principalsFile;
        mode = "0444";
        user = "root";
        group = "wheel";
      };

      services.openssh.extraConfig = lib.mkIf tickets.enable ''
        TrustedUserCAKeys ${caPublicKeyPath}
        AuthorizedPrincipalsFile ${principalsPath}
      '';
    })
  ];
}
