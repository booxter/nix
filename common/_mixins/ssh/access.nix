{
  config,
  lib,
  outputs,
  system,
  ...
}:
let
  localHost = config.networking.hostName;
  platform = lib.systems.elaborate system;
  username = config.host.username;
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = removeAttrs configurations [ localHost ];
  fleetHosts = lib.mapAttrs (_: configuration: configuration.config.host) otherConfigurations // {
    ${localHost} = config.host;
  };
  operatorHostView = host: {
    inherit (host) realm;
    operator = host.security.secrets.operator.ageIdentity != null;
    authorizedKeys = host.ssh.operator.authorizedKeys;
  };
  operatorHosts = lib.mapAttrs (_: operatorHostView) fleetHosts;
  realmOperatorHosts = lib.filterAttrs (
    _: host: host.operator && host.realm == config.host.realm
  ) operatorHosts;
  realmAuthorizedKeys = lib.unique (
    builtins.concatMap (host: host.authorizedKeys) (builtins.attrValues realmOperatorHosts)
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
    ];

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
