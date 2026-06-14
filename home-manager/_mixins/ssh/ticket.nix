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
  hasCaPublicKey = hostInventory.sshTicket.userCaPublicKey != null;
  ticketStateDir = "${config.home.homeDirectory}/.local/state/ssh-ticket";
  ticketKeyPath = "${config.home.homeDirectory}/.ssh/fleet-ticket/id_ed25519";
  mkTarget =
    {
      kind,
      name,
      sshHost ? name,
      dnsName ? sshHost,
      aliases ? [ name ],
      isWork ? false,
    }:
    let
      enabled = !isWork;
    in
    {
      inherit
        enabled
        kind
        name
        sshHost
        ;
      aliases = lib.unique ([ name ] ++ aliases);
      principal = if enabled then "${username}@${dnsName}" else "";
      defaultTtl = "30m";
      maxTtl = "2h";
      caPublicKeyConfigured = enabled && hasCaPublicKey;
    };
  mkDarwinTarget =
    name: spec:
    mkTarget {
      kind = "darwin";
      inherit name;
      aliases = [
        (spec.hostname or name)
        (spec.dnsName or (spec.hostname or name))
      ];
      dnsName = spec.dnsName or (spec.hostname or name);
      isWork = spec.isWork or false;
    };
  mkNixosTarget =
    spec:
    if hostInventory.isNixosVM spec then
      let
        sshHost = hostInventory.toNixosShortDnsName spec;
      in
      mkTarget {
        kind = "nixos";
        name = spec.name;
        inherit sshHost;
        aliases = [ spec.name ];
        isWork = spec.isWork or false;
      }
    else
      mkTarget {
        kind = "nixos";
        name = spec.name;
        aliases = [
          (spec.hostname or spec.name)
          (spec.dnsName or (spec.hostname or spec.name))
        ];
        dnsName = spec.dnsName or (spec.hostname or spec.name);
        isWork = spec.isWork or false;
      };
  ticketTargets =
    map mkNixosTarget hostInventory.nixosHostSpecs
    ++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts;
  ticketTargetsFile = pkgs.writeText "ssh-ticket-targets.json" (builtins.toJSON ticketTargets);
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
        HostKeyAlias = target.name;
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
      ensureCommand = "${pkgs.ssh-ticket}/bin/ssh-ticket ensure --targets-file ${ticketTargetsFile} --quiet --gui --cert-alias %n ${target.name}";
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

  config = {
    home.sessionVariables.SSHT_TARGETS_FILE = "${ticketTargetsFile}";

    programs.ssh.settings = lib.mkIf cfg.enableKnownHosts ticketKnownHostSettings;
  };
}
