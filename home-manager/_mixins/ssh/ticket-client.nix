{
  config,
  hostInventory,
  lib,
  pkgs,
  username,
  ...
}:
let
  homeManagerPkgs = import ../../pkgs pkgs;
  ticketPackage = homeManagerPkgs.ssh-ticket;
  cfg = config.programs.sshTicket;
  ticketStateDir = "${config.home.homeDirectory}/.local/state/ssh-ticket";
  ticketKeyPath = "${config.home.homeDirectory}/.ssh/fleet-ticket/id_ed25519";
  ticketTargets = import ../../../lib/ssh-ticket-targets.nix {
    inherit
      hostInventory
      lib
      username
      ;
  };
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
      ensureCommand = "${ticketPackage}/bin/ssh-ticket ensure --targets-file ${ticketTargetsFile} --quiet --gui --cert-alias %n ${target.name}";
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
    home.packages = [ ticketPackage ];

    home.sessionVariables.SSHT_TARGETS_FILE = "${ticketTargetsFile}";

    programs.ssh.settings = lib.mkIf cfg.enableKnownHosts ticketKnownHostSettings;
  };
}
