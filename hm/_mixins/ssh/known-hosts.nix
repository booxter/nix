{
  config,
  lib,
  ...
}:
let
  knownHostModule =
    { name, ... }:
    {
      options = {
        hostNames = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
          default = [ name ];
          description = "SSH host patterns that use this known-host entry.";
        };

        publicKeys = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
          description = "Complete known_hosts records trusted for this host.";
        };
      };
    };
  cfg = config.host.hm.ssh.knownHosts;
in
{
  options.host.hm.ssh.knownHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule knownHostModule);
    default = { };
    description = "Per-user SSH known-host entries.";
  };

  config = lib.mkIf (config.host.hm.userEnvironment.preset != null) {
    home.file = lib.mapAttrs' (
      name: knownHost:
      lib.nameValuePair ".ssh/known_hosts.d/${name}" {
        text = lib.concatStringsSep "\n" knownHost.publicKeys + "\n";
      }
    ) cfg;

    programs.ssh.settings = lib.mapAttrs (name: knownHost: {
      header = "Host ${lib.concatStringsSep " " knownHost.hostNames}";
      HostKeyAlias = name;
      UserKnownHostsFile = "~/.ssh/known_hosts.d/${name}";
    }) cfg;
  };
}
