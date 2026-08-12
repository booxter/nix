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

    programs.ssh.knownHosts = managedKnownHosts;

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
