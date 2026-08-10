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
  caPublicKeyPath = "/etc/ssh/fleet-user-cas.pub";
  caPublicKeyFile = pkgs.writeText "fleet-user-cas.pub" (
    lib.concatMapStrings (publicKey: "${publicKey}\n") target.trustedCaPublicKeys
  );
  principalsFile = pkgs.writeText "${username}-authorized_principals" "${principal}\n";
in
{
  config = lib.mkMerge [
    (lib.optionalAttrs isLinux {
      environment.etc."ssh/fleet-user-cas.pub" = lib.mkIf target.enabled {
        source = caPublicKeyFile;
      };

      services.openssh.settings.TrustedUserCAKeys = lib.mkIf target.enabled caPublicKeyPath;
      users.users.${username}.openssh.authorizedPrincipals = lib.mkIf target.enabled [
        principal
      ];
    })
    (lib.optionalAttrs isDarwin {
      environment.etc = {
        "ssh/fleet-user-cas.pub" = lib.mkIf target.enabled {
          source = caPublicKeyFile;
          mode = "0444";
          user = "root";
          group = "wheel";
        };
        "ssh/authorized_principals.d/${username}" = lib.mkIf target.enabled {
          source = principalsFile;
          mode = "0444";
          user = "root";
          group = "wheel";
        };
      };

      services.openssh.extraConfig = lib.mkIf target.enabled ''
        TrustedUserCAKeys ${caPublicKeyPath}
        AuthorizedPrincipalsFile /etc/ssh/authorized_principals.d/%u
      '';
    })
  ];
}
