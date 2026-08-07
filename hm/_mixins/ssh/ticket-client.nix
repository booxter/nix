{
  config,
  hostInventory,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  username = config.home.username;
  hostname = osConfig.networking.hostName;
  realm = osConfig.host.realm;
  homeManagerPkgs = import ../../pkgs pkgs;
  ticketPackage = homeManagerPkgs.ssh-ticket;
  issuer = hostInventory.sshTicket.issuers.${hostname} or null;
  ticketStateDir = "${config.xdg.stateHome}/ssh-ticket";
  ticketKeyPath = "${config.home.homeDirectory}/.ssh/fleet-ticket/id_ed25519";
  caKeyPath = "${config.home.homeDirectory}/.ssh/${issuer.keyName}";
  caSigningArgs = if issuer.useAgent then "--ca-agent" else "--no-ca-agent";
  ticketTargets = builtins.filter (target: target.realm == realm) hostInventory.sshTicket.targets;
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
  config = lib.mkIf (osConfig.host.ssh.tickets.enable && issuer != null) {
    home.packages = [ ticketPackage ];

    home.sessionVariables.SSHT_TARGETS_FILE = "${ticketTargetsFile}";

    home.file.".ssh/fleet-user-ca.pub" = lib.mkIf issuer.useAgent {
      text = "${issuer.publicKey}\n";
    };

    assertions = [
      {
        assertion = lib.elem issuer.publicKey hostInventory.sshTicket.trustedCaPublicKeysByRealm.${realm};
        message = "SSH ticket issuer for ${hostname} is not trusted by ticket servers";
      }
    ];

    programs.ssh.settings = ticketKnownHostSettings;
  };
}
