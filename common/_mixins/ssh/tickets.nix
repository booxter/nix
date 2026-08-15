{
  config,
  lib,
  outputs,
  ...
}:
let
  localHost = config.networking.hostName;
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = removeAttrs configurations [ localHost ];
  fleetHosts = lib.mapAttrs (_: configuration: configuration.config.host) otherConfigurations // {
    ${localHost} = config.host;
  };
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
      allowX11Forwarding = lib.mkOption { type = lib.types.bool; };
      defaultTtl = lib.mkOption { type = lib.types.nonEmptyStr; };
      maxTtl = lib.mkOption { type = lib.types.nonEmptyStr; };
    };
  };
  ticketTargetFor =
    name: configuration:
    let
      tickets = configuration.config.host.ssh.tickets;
    in
    {
      inherit name;
      inherit (tickets)
        allowX11Forwarding
        defaultTtl
        maxTtl
        ;
    };
  realmTicketConfigurations = lib.filterAttrs (
    _: configuration: configuration.config.host.realm == config.host.realm
  ) configurations;
  ticketTargets = lib.mapAttrsToList ticketTargetFor realmTicketConfigurations;
in
{
  options.host.ssh.tickets = {
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
}
