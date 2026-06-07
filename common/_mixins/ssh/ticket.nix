{
  config,
  hostInventory,
  isWork,
  lib,
  options,
  username,
  ...
}:
let
  cfg = config.host.sshTicket;
  caPublicKeyPath = "/etc/ssh/fleet-user-ca.pub";
  inventoryCaPublicKey = hostInventory.sshTicket.userCaPublicKey;
  hasOpenSshSettings = lib.hasAttrByPath [
    "services"
    "openssh"
    "settings"
  ] options;
  hostName = config.networking.hostName;
  shortProxVmAliases = lib.optionals (lib.hasPrefix "prox-" hostName && lib.hasSuffix "vm" hostName) [
    (builtins.substring 5 ((builtins.stringLength hostName) - 7) hostName)
  ];
in
{
  options.host.sshTicket = {
    enable = lib.mkEnableOption "short-lived SSH user certificate access";

    caPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.singleLineStr;
      default = null;
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... fleet-user-ca";
      description = ''
        Public key of the SSH user CA trusted for short-lived login tickets.
        Leave null while staging per-host principals without enabling certificate
        authentication on the server.
      '';
    };

    principal = lib.mkOption {
      type = lib.types.singleLineStr;
      default = "${username}@${config.host.dnsName}";
      defaultText = lib.literalExpression ''"${username}@${config.host.dnsName}"'';
      description = "Certificate principal accepted for ${username} on this host.";
    };

    aliases = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = lib.unique (
        [
          config.networking.hostName
          config.host.dnsName
        ]
        ++ shortProxVmAliases
      );
      defaultText = lib.literalExpression "[ config.networking.hostName config.host.dnsName ] ++ shortProxVmAliases";
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
      host.sshTicket.enable = lib.mkDefault (!isWork);
      host.sshTicket.caPublicKey = lib.mkIf cfg.enable (lib.mkDefault inventoryCaPublicKey);
    }
    (lib.optionalAttrs hasOpenSshSettings {
      environment.etc."ssh/fleet-user-ca.pub" = lib.mkIf (cfg.enable && cfg.caPublicKey != null) {
        text = "${cfg.caPublicKey}\n";
      };

      services.openssh.settings.TrustedUserCAKeys = lib.mkIf (
        cfg.enable && cfg.caPublicKey != null
      ) caPublicKeyPath;

      users.users.${username}.openssh.authorizedPrincipals = lib.mkIf cfg.enable [
        cfg.principal
      ];
    })
  ];
}
