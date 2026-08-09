{
  config,
  hostInventory,
  hostSpec,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  isDarwin = lib.hasSuffix "-darwin" hostSpec.platform;
  isLinux = lib.hasSuffix "-linux" hostSpec.platform;
  target = hostInventory.ssh-ticket.targetsByName.${config.networking.hostName};
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
      services.openssh.extraConfig = lib.mkIf target.enabled ''
        TrustedUserCAKeys ${caPublicKeyPath}
        AuthorizedPrincipalsFile /etc/ssh/authorized_principals.d/%u
      '';

      system.activationScripts.etc.text = lib.mkIf target.enabled (
        lib.mkAfter ''
          # nix-darwin environment.etc only creates symlinks. Mirror NixOS'
          # copied /etc files here because sshd StrictModes rejects cert auth
          # files reached through group-writable /nix/store parents.
          # TODO: expand nix-darwin environment.etc to support NixOS-style
          # copy mode/owner semantics, then replace this targeted workaround.
          install -d -m 0755 -o root -g wheel /etc/ssh/authorized_principals.d

          install -m 0444 -o root -g wheel \
            "${caPublicKeyFile}" \
            /etc/ssh/fleet-user-cas.pub.tmp
          mv -f /etc/ssh/fleet-user-cas.pub.tmp /etc/ssh/fleet-user-cas.pub

          install -m 0444 -o root -g wheel \
            "${principalsFile}" \
            /etc/ssh/authorized_principals.d/${username}.tmp
          mv -f \
            /etc/ssh/authorized_principals.d/${username}.tmp \
            /etc/ssh/authorized_principals.d/${username}
        ''
      );
    })
  ];
}
