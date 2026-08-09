{
  config,
  facts,
  lib,
  ...
}:
let
  username = config.host.username;
  realmSsh = facts.realms.${config.host.realm}.trust.ssh;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  hostKeyPath = name: ../../../public-keys/hosts + "/${name}.pub";
  managedKnownHosts = lib.mapAttrs (name: spec: {
    hostNames = spec.sshKnownHostNames;
    publicKey = readPublicKey (hostKeyPath name);
  }) facts.hosts.hostSpecsByName;
in
{
  imports = [ ./ticket-server.nix ];

  options.host.ssh = {
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

    tickets.enable = lib.mkOption {
      type = lib.types.bool;
      default = realmSsh ? tickets;
      readOnly = true;
      internal = true;
      description = "Whether this realm participates in SSH ticket authentication.";
    };
  };

  config = {
    services.openssh.enable = true;

    programs.ssh.knownHosts = managedKnownHosts // {
      frame-initrd = {
        hostNames = [ "frame-initrd" ];
        publicKey = readPublicKey ../../../public-keys/hosts/frame-initrd.pub;
      };
    };

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
