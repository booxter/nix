{
  config,
  hostInventory,
  hostname,
  hostSpecName ? hostname,
  isDarwin,
  isLinux,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.host.sshTicket;
  caPublicKeyPath = "/etc/ssh/fleet-user-cas.pub";
  inventoryCaPublicKeys = hostInventory.sshTicket.trustedCaPublicKeys;
  caPublicKeyFile = pkgs.writeText "fleet-user-cas.pub" (
    lib.concatMapStrings (publicKey: "${publicKey}\n") cfg.caPublicKeys
  );
  principalsFile = pkgs.writeText "${username}-authorized_principals" (
    lib.concatMapStrings (principal: "${principal}\n") cfg.principals
  );
  defaultPrincipalNames = lib.unique [
    config.host.dnsName
    config.networking.hostName
    hostSpecName
  ];
in
{
  options.host.sshTicket = {
    enable = lib.mkEnableOption "short-lived SSH user certificate access";

    caPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = [ ];
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... fleet-user-ca" ];
      description = ''
        Public keys of the SSH user CAs trusted for short-lived login tickets.
        Leave empty while staging per-host principals without enabling
        certificate authentication on the server.
      '';
    };

    principal = lib.mkOption {
      type = lib.types.singleLineStr;
      default = "${username}@${config.host.dnsName}";
      defaultText = lib.literalExpression ''"${username}@${config.host.dnsName}"'';
      description = "Certificate principal accepted for ${username} on this host.";
    };

    principalNames = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = defaultPrincipalNames;
      defaultText = lib.literalExpression ''
        lib.unique [
          config.host.dnsName
          config.networking.hostName
          hostSpecName
        ]
      '';
      description = "Host identity names accepted as SSH certificate principals for ${username}.";
    };

    principals = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = lib.unique ([ cfg.principal ] ++ map (name: "${username}@${name}") cfg.principalNames);
      defaultText = lib.literalExpression ''
        lib.unique (
          [ config.host.sshTicket.principal ]
          ++ map (name: username + "@" + name) config.host.sshTicket.principalNames
        )
      '';
      description = "Full SSH certificate principals accepted for ${username}.";
    };

    aliases = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = lib.unique ([
        config.networking.hostName
        config.host.dnsName
        hostSpecName
      ]);
      defaultText = lib.literalExpression "[ config.networking.hostName config.host.dnsName hostSpecName ]";
      description = "Client-side names that resolve to this ticket scope.";
    };

    defaultTtl = lib.mkOption {
      type = lib.types.singleLineStr;
      default = "30m";
      description = "Default lifetime requested by ssht when issuing a host ticket.";
    };

    maxTtl = lib.mkOption {
      type = lib.types.singleLineStr;
      default = "2h";
      description = "Maximum lifetime ssht may request for a host ticket.";
    };
  };

  config = lib.mkMerge [
    {
      host.sshTicket.enable = lib.mkDefault true;
      host.sshTicket.caPublicKeys = lib.mkIf cfg.enable (lib.mkDefault inventoryCaPublicKeys);
    }
    (lib.optionalAttrs isLinux {
      environment.etc."ssh/fleet-user-cas.pub" = lib.mkIf (cfg.enable && cfg.caPublicKeys != [ ]) {
        source = caPublicKeyFile;
      };
    })
    (lib.optionalAttrs isLinux {
      services.openssh.settings.TrustedUserCAKeys = lib.mkIf (
        cfg.enable && cfg.caPublicKeys != [ ]
      ) caPublicKeyPath;

      users.users.${username}.openssh.authorizedPrincipals = lib.mkIf cfg.enable cfg.principals;
    })
    (lib.optionalAttrs isDarwin {
      services.openssh.extraConfig = lib.mkIf (cfg.enable && cfg.caPublicKeys != [ ]) ''
        TrustedUserCAKeys ${caPublicKeyPath}
        AuthorizedPrincipalsFile /etc/ssh/authorized_principals.d/%u
      '';

      system.activationScripts.etc.text = lib.mkIf (cfg.enable && cfg.caPublicKeys != [ ]) (
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
