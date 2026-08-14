{
  config,
  lib,
  outputs,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  localHost = config.networking.hostName;
  username = config.host.username;
  readPublicKey = import ../../_lib/read-public-key.nix { inherit lib; };
  hostDirectory = (if isDarwin then ../../../darwin else ../../../nixos) + "/${localHost}";
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  hostConfigurationFor = name: if name == localHost then config else configurations.${name}.config;
  managedKnownHosts = lib.mapAttrs (name: _: {
    hostNames = (hostConfigurationFor name).host.ssh.knownHostNames;
    publicKey = (hostConfigurationFor name).host.ssh.publicHostKey;
  }) configurations;
  operatorHostView = host: {
    inherit (host) realm;
    operator = host.security.secrets.operator.enable;
    authorizedKeys = host.ssh.operator.authorizedKeys;
  };
  otherConfigurations = removeAttrs configurations [ localHost ];
  fleetHosts = lib.mapAttrs (_: configuration: configuration.config.host) otherConfigurations // {
    ${localHost} = config.host;
  };
  operatorHosts = lib.mapAttrs (_: operatorHostView) fleetHosts;
  realmOperatorHosts = lib.filterAttrs (
    _: host: host.operator && host.realm == config.host.realm
  ) operatorHosts;
  realmAuthorizedKeys = lib.unique (
    builtins.concatMap (host: host.authorizedKeys) (builtins.attrValues realmOperatorHosts)
  );
  preBootEndpointType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        hostName = lib.mkOption { type = lib.types.nonEmptyStr; };
        hostKeyAlias = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
        };
        publicHostKey = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
        };
        user = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Remote user, or the local user when unset.";
        };
        authentication = lib.mkOption {
          type = lib.types.enum [
            "password"
            "public-key"
          ];
        };
        requestTTY = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
      };
    }
  );
  preBootKnownHosts = lib.mapAttrs' (
    _: endpoint:
    lib.nameValuePair endpoint.hostKeyAlias {
      hostNames = [ endpoint.hostKeyAlias ];
      publicKey = endpoint.publicHostKey;
    }
  ) (lib.filterAttrs (_: endpoint: endpoint.publicHostKey != null) config.host.ssh.preBoot.endpoints);
  ticketIssuerType = lib.types.submodule {
    options = {
      publicKey = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Public key corresponding to the SSH user CA issuer.";
      };
      keyName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Filename of the SSH user CA key below the user's .ssh directory.";
      };
      useAgent = lib.mkOption {
        type = lib.types.bool;
        description = "Whether the issuer signs through ssh-agent instead of a private-key file.";
      };
    };
  };
  realmTicketIssuerHosts = lib.filterAttrs (
    _: host: host.realm == config.host.realm && host.ssh.tickets.issuer != null
  ) fleetHosts;
  realmTrustedCaPublicKeys = lib.unique (
    map (host: host.ssh.tickets.issuer.publicKey) (builtins.attrValues realmTicketIssuerHosts)
  );
  ticketTargetType = lib.types.submodule {
    options = {
      name = lib.mkOption { type = lib.types.nonEmptyStr; };
      enabled = lib.mkOption { type = lib.types.bool; };
      sshHost = lib.mkOption { type = lib.types.nonEmptyStr; };
      aliases = lib.mkOption { type = lib.types.nonEmptyListOf lib.types.nonEmptyStr; };
      allowX11Forwarding = lib.mkOption { type = lib.types.bool; };
      defaultTtl = lib.mkOption { type = lib.types.nonEmptyStr; };
      maxTtl = lib.mkOption { type = lib.types.nonEmptyStr; };
      caPublicKeyConfigured = lib.mkOption { type = lib.types.bool; };
      realm = lib.mkOption { type = lib.types.nonEmptyStr; };
      trustedCaPublicKeys = lib.mkOption { type = lib.types.listOf lib.types.nonEmptyStr; };
    };
  };
  ticketTargetFor =
    name: configuration:
    let
      host = configuration.config.host;
      tickets = host.ssh.tickets;
    in
    {
      inherit name;
      inherit (tickets)
        allowX11Forwarding
        defaultTtl
        maxTtl
        trustedCaPublicKeys
        ;
      enabled = tickets.enable;
      sshHost = name;
      aliases = [
        name
        "${name}.local"
      ];
      caPublicKeyConfigured = tickets.enable && tickets.trustedCaPublicKeys != [ ];
      inherit (host) realm;
    };
  ticketTargets = lib.mapAttrsToList ticketTargetFor configurations;
  issuer = config.host.ssh.tickets.issuer;
  issuerTargets = builtins.filter (
    target: target.enabled && target.realm == config.host.realm
  ) config.host.ssh.tickets.targets;
in
{
  imports = [
    ./home.nix
    ./ticket-server.nix
  ];

  options.host.ssh = {
    knownHostNames = lib.mkOption {
      type = with lib.types; nonEmptyListOf nonEmptyStr;
      default =
        let
          lowercaseName = lib.toLower localHost;
        in
        lib.unique (
          [ localHost ]
          ++ lib.optional (lowercaseName != localHost) lowercaseName
          ++ lib.optional config.nixpkgs.hostPlatform.isLinux "${localHost}.${config.host.network.lanDomain}"
          ++ [ "${localHost}.local" ]
          ++ lib.optional (lowercaseName != localHost) "${lowercaseName}.local"
        );
      description = "Names associated with this host in managed SSH known-host entries.";
    };

    publicHostKey = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = readPublicKey (hostDirectory + "/ssh_host_ed25519_key.pub");
      readOnly = true;
      internal = true;
      description = "SSH host public key published to the managed fleet.";
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

    preBoot.endpoints = lib.mkOption {
      type = lib.types.attrsOf preBootEndpointType;
      default = { };
      description = "Pre-boot SSH endpoints available in this host's realm.";
    };

    tickets = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = realmTrustedCaPublicKeys != [ ];
        description = "Whether this host accepts SSH user certificates.";
      };

      trustedCaPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = realmTrustedCaPublicKeys;
        readOnly = true;
        internal = true;
        description = "SSH user CA public keys contributed by issuer hosts in this realm.";
      };

      allowX11Forwarding = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether tickets issued for this host may permit X11 forwarding.";
      };

      defaultTtl = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "30m";
        description = "Default lifetime of SSH tickets issued for this host.";
      };

      maxTtl = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "2h";
        description = "Maximum lifetime of SSH tickets issued for this host.";
      };

      issuer = lib.mkOption {
        type = lib.types.nullOr ticketIssuerType;
        default = null;
        description = "SSH user CA available from this operator host.";
      };

      targets = lib.mkOption {
        type = lib.types.listOf ticketTargetType;
        default = ticketTargets;
        readOnly = true;
        internal = true;
        description = "SSH ticket targets derived from evaluated fleet host options.";
      };
    };
  };

  config = {
    assertions =
      lib.optionals (issuer != null) [
        {
          assertion = config.host.ssh.tickets.enable;
          message = "an SSH ticket issuer may only be configured on a ticket-enabled host";
        }
        {
          assertion = lib.all (target: lib.elem issuer.publicKey target.trustedCaPublicKeys) issuerTargets;
          message = "SSH ticket issuer for ${config.networking.hostName} is not trusted by every enabled target in its realm";
        }
      ]
      ++ [
        {
          assertion =
            config.host.ssh.operator.authorizedKeys == [ ] || config.host.security.secrets.operator.enable;
          message = "only operator hosts may contribute realm SSH authorized keys";
        }
        {
          assertion = config.host.ssh.authorizedKeys != [ ];
          message = "realm '${config.host.realm}' must have at least one operator SSH authorized key";
        }
      ];

    services.openssh.enable = true;

    programs.ssh.knownHosts = managedKnownHosts // preBootKnownHosts;

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
