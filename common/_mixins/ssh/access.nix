{
  config,
  fleetInventory,
  lib,
  system,
  ...
}:
let
  platform = lib.systems.elaborate system;
  username = config.host.username;
  localInventory = fleetInventory.hosts.${config.networking.hostName};
  realmOperatorHosts = lib.filterAttrs (
    _: host: host.realm == config.host.realm && host.ssh.operatorAuthorizedKeys != [ ]
  ) fleetInventory.hosts;
  realmAuthorizedKeys = lib.unique (
    builtins.concatMap (host: host.ssh.operatorAuthorizedKeys) (builtins.attrValues realmOperatorHosts)
  );
in
{
  options.host.ssh = {
    credentials.backend = lib.mkOption {
      type = lib.types.enum (
        [
          "files"
          "yubikey"
        ]
        ++ lib.optional platform.isDarwin "secretive"
      );
      default = "files";
      description = "Backend providing the operator's SSH authentication and signing identity.";
    };

    authorizedKeys = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = realmAuthorizedKeys;
      readOnly = true;
      internal = true;
      description = "Authorized SSH keys contributed by operator hosts in this realm.";
    };

    operator.authorizedKeys = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "SSH public keys controlled by this operator host and authorized across its realm.";
    };
  };

  config = {
    assertions = [
      {
        assertion =
          config.host.ssh.operator.authorizedKeys == [ ]
          || config.host.security.secrets.operator.ageIdentity != null;
        message = "only operator hosts may contribute realm SSH authorized keys";
      }
      {
        assertion = config.host.ssh.authorizedKeys != [ ];
        message = "realm '${config.host.realm}' must have at least one operator SSH authorized key";
      }
      {
        assertion = localInventory.realm == config.host.realm && localInventory.system == system;
        message = "local host realm and system must match fleet inventory";
      }
      {
        assertion = localInventory.ssh.operatorAuthorizedKeys == config.host.ssh.operator.authorizedKeys;
        message = "local SSH operator keys must match fleet inventory";
      }
    ];

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
