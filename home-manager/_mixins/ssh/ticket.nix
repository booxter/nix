{
  config,
  hostInventory,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.programs.sshTicket;
  ticketStateDir = "${config.home.homeDirectory}/.local/state/ssh-ticket";
  ticketKeyPath = "${config.home.homeDirectory}/.ssh/fleet-ticket/id_ed25519";
  mkTarget =
    {
      name,
      sshHost ? name,
      aliases ? [ name ],
      isWork ? false,
    }:
    {
      inherit name sshHost;
      aliases = lib.unique ([ name ] ++ aliases);
      enabled = !isWork;
    };
  mkDarwinTarget =
    name: spec:
    mkTarget {
      inherit name;
      aliases = [
        (spec.hostname or name)
        (spec.dnsName or (spec.hostname or name))
      ];
      isWork = spec.isWork or false;
    };
  mkNixosTarget =
    spec:
    if spec.type == "bm" then
      mkTarget {
        name = spec.name;
        aliases = [
          (spec.hostname or spec.name)
          (spec.dnsName or (spec.hostname or spec.name))
        ];
        isWork = spec.isWork or false;
      }
    else if spec.type == "vm" then
      let
        name = "prox-${spec.name}vm";
      in
      mkTarget {
        inherit name;
        aliases = [ spec.name ];
        isWork = spec.isWork or false;
      }
    else
      throw "Unsupported NixOS host spec type `${spec.type}` for SSH ticket client config.";
  ticketTargets =
    map mkNixosTarget hostInventory.nixosHostSpecs
    ++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts;
  enabledTicketTargets = builtins.filter (target: target.enabled) ticketTargets;
  ticketHostBlock =
    target:
    let
      patterns = target.aliases;
    in
    {
      name = "ssh-ticket-host-${target.name}";
      value = lib.hm.dag.entryBefore [ "*" ] {
        header = "Host ${lib.concatStringsSep " " patterns}";
        HostName = target.sshHost;
        User = username;
        IdentitiesOnly = true;
        IdentityFile = ticketKeyPath;
        CertificateFile = "${ticketStateDir}/%n-cert.pub";
        ForwardAgent = false;
        AddKeysToAgent = "no";
        ControlMaster = "no";
        ControlPath = "none";
        PreferredAuthentications = "publickey";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PubkeyAuthentication = true;
      };
    };
  ticketEnsureBlock =
    target:
    let
      patterns = target.aliases;
      ensureCommand = "${pkgs.ssh-ticket}/bin/ssh-ticket ensure --quiet --gui --cert-alias %n ${target.name}";
    in
    {
      name = "ssh-ticket-ensure-${target.name}";
      value = lib.hm.dag.entryBefore [ "*" ] {
        header = "Match originalhost ${lib.concatStringsSep "," patterns} exec \"${ensureCommand}\"";
        IdentitiesOnly = true;
      };
    };
  ticketKnownHostSettings = builtins.listToAttrs (
    builtins.concatMap (target: [
      (ticketHostBlock target)
      (ticketEnsureBlock target)
    ]) enabledTicketTargets
  );
in
{
  options.programs.sshTicket.enableKnownHosts = lib.mkEnableOption "OpenSSH config for known ssh-ticket hosts";

  config.programs.ssh.settings = lib.mkIf cfg.enableKnownHosts ticketKnownHostSettings;
}
