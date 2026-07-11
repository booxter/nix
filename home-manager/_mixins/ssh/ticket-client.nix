{
  config,
  hostInventory,
  hostSpecName,
  lib,
  pkgs,
  username,
  ...
}:
let
  homeManagerPkgs = import ../../pkgs pkgs;
  ticketPackage = homeManagerPkgs.ssh-ticket;
  cfg = config.programs.sshTicket;
  issuer = hostInventory.sshTicket.issuers.${hostSpecName} or null;
  ticketStateDir = "${config.home.homeDirectory}/.local/state/ssh-ticket";
  ticketKeyPath = "${config.home.homeDirectory}/.ssh/fleet-ticket/id_ed25519";
  caKeyPath = "${config.home.homeDirectory}/.ssh/${issuer.keyName}";
  caSigningArgs = if issuer.useAgent then "--ca-agent" else "--no-ca-agent";
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
      ensureCommand = "${ticketPackage}/bin/ssh-ticket ensure --targets-file ${ticketTargetsFile} --quiet --ca-key ${caKeyPath} ${caSigningArgs} --cert-alias %n ${target.name}";
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

    home.file.".ssh/fleet-user-ca.pub" = lib.mkIf cfg.enableKnownHosts {
      text = "${issuer.publicKey}\n";
    };

    assertions = [
      {
        assertion = !cfg.enableKnownHosts || issuer != null;
        message = "programs.sshTicket.enableKnownHosts requires an SSH ticket issuer for ${hostSpecName}";
      }
      {
        assertion = issuer == null || lib.elem issuer.publicKey hostInventory.sshTicket.trustedCaPublicKeys;
        message = "SSH ticket issuer for ${hostSpecName} is not trusted by ticket servers";
      }
    ];

    programs.ssh.settings = lib.mkIf cfg.enableKnownHosts ticketKnownHostSettings;
  };
}
