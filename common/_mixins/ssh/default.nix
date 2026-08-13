{
  config,
  facts,
  hostSpec,
  isDarwin,
  lib,
  outputs,
  ...
}:
let
  username = config.host.username;
  realmSsh = facts.realms.${config.host.realm}.trust.ssh;
  readPublicKey = import ../../_lib/read-public-key.nix { inherit lib; };
  hostDirectory = (if isDarwin then ../../../darwin else ../../../nixos) + "/${hostSpec.name}";
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  publicHostKeyFor =
    name:
    if name == hostSpec.name then
      config.host.ssh.publicHostKey
    else
      configurations.${name}.config.host.ssh.publicHostKey;
  managedKnownHosts = lib.mapAttrs (name: spec: {
    hostNames = spec.sshKnownHostNames;
    publicKey = publicHostKeyFor name;
  }) facts.hosts.hostSpecsByName;
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
  ticketTargetType = lib.types.submodule {
    options = {
      name = lib.mkOption { type = lib.types.nonEmptyStr; };
      enabled = lib.mkOption { type = lib.types.bool; };
      kind = lib.mkOption {
        type = lib.types.enum [
          "darwin"
          "nixos"
        ];
      };
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
      kind = if host.isDarwin then "darwin" else "nixos";
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
  imports = [ ./ticket-server.nix ];

  options.host.ssh = {
    publicHostKey = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = readPublicKey (hostDirectory + "/ssh_host_ed25519_key.pub");
      readOnly = true;
      internal = true;
      description = "SSH host public key published to the managed fleet.";
    };

    authorizedKeys = lib.mkOption {
      type = with lib.types; listOf str;
      default = realmSsh.authorizedKeys;
      readOnly = true;
      internal = true;
      description = "Authorized SSH keys selected by the host realm.";
    };

    fleetBootHosts = lib.mkOption {
      type = lib.types.bool;
      default = realmSsh.fleetBootHosts or false;
      readOnly = true;
      internal = true;
      description = "Whether SSH clients should expose home fleet pre-boot aliases.";
    };

    tickets = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = realmSsh ? tickets;
        description = "Whether this host accepts SSH user certificates.";
      };

      trustedCaPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = realmSsh.tickets.trustedCaPublicKeys or [ ];
        description = "SSH user CA public keys trusted by this host.";
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
    assertions = lib.optionals (issuer != null) [
      {
        assertion = config.host.ssh.tickets.enable;
        message = "an SSH ticket issuer may only be configured on a ticket-enabled host";
      }
      {
        assertion = lib.all (target: lib.elem issuer.publicKey target.trustedCaPublicKeys) issuerTargets;
        message = "SSH ticket issuer for ${config.networking.hostName} is not trusted by every enabled target in its realm";
      }
    ];

    services.openssh.enable = true;

    programs.ssh.knownHosts = managedKnownHosts;

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
