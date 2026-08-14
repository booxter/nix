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
  readPublicKey = import ../../_lib/read-public-key.nix { inherit lib; };
  hostDirectory = (if platform.isDarwin then ../../../darwin else ../../../nixos) + "/${localHost}";
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  hostConfigurationFor = name: if name == localHost then config else configurations.${name}.config;
  managedKnownHosts = lib.mapAttrs (name: _: {
    hostNames = (hostConfigurationFor name).host.ssh.knownHostNames;
    publicKey = (hostConfigurationFor name).host.ssh.publicHostKey;
  }) configurations;
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

  config.programs.ssh.knownHosts = managedKnownHosts // preBootKnownHosts;
}
