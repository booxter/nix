{
  config,
  fleetInventory,
  lib,
  system,
  ...
}:
let
  localHost = config.networking.hostName;
  platform = lib.systems.elaborate system;
  readPublicKey = import ../../_lib/read-public-key.nix { inherit lib; };
  hostDirectory = (if platform.isDarwin then ../../../darwin else ../../../nixos) + "/${localHost}";
  localInventory = fleetInventory.hosts.${localHost};
  managedKnownHosts = lib.mapAttrs (_: host: {
    hostNames = host.ssh.knownHostNames;
    publicKey = host.ssh.publicHostKey;
  }) fleetInventory.hosts;
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
in
{
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
          ++ lib.optional platform.isLinux "${localHost}.${config.host.network.lanDomain}"
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

    preBoot.endpoints = lib.mkOption {
      type = lib.types.attrsOf preBootEndpointType;
      default = { };
      description = "Pre-boot SSH endpoints available in this host's realm.";
    };
  };

  config = {
    assertions = [
      {
        assertion = localInventory.ssh.knownHostNames == config.host.ssh.knownHostNames;
        message = "local SSH known-host names must match fleet inventory";
      }
      {
        assertion = localInventory.ssh.publicHostKey == config.host.ssh.publicHostKey;
        message = "local SSH host public key must match fleet inventory";
      }
    ];

    programs.ssh.knownHosts = managedKnownHosts // preBootKnownHosts;
  };
}
