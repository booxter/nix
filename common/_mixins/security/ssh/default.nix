{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  realmSsh = hostInventory.realms.${config.host.realm}.trust.ssh;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  hostKeyPath = name: ../../../../public-keys/hosts + "/${name}.pub";
  managedKnownHosts = lib.mapAttrs (name: spec: {
    hostNames = hostInventory.toSshKnownHostNames spec;
    publicKey = readPublicKey (hostKeyPath name);
  }) hostInventory.hostSpecsByName;
in
{
  imports = [ ./ticket-server.nix ];

  options.host.ssh = {
    authorizedKeys = lib.mkOption {
      type = with lib.types; listOf str;
      default = realmSsh.authorizedKeys ++ hostInventory.ssh.authorizedKeysForHost hostname;
      readOnly = true;
      internal = true;
      description = "Authorized SSH keys selected by realm and host-specific grants.";
    };

    fleetBootHosts = lib.mkOption {
      type = lib.types.bool;
      default = realmSsh.fleetBootHosts or false;
      readOnly = true;
      internal = true;
      description = "Whether SSH clients should expose home fleet pre-boot aliases.";
    };

    userDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.users.users.${username}.home}/.ssh";
      readOnly = true;
      internal = true;
      description = "Primary user's OpenSSH directory.";
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

    programs.ssh.knownHosts = managedKnownHosts // (realmSsh.knownHosts or { });

    users.users.${username}.openssh.authorizedKeys.keys = config.host.ssh.authorizedKeys;
  };
}
