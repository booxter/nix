{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  username = osConfig.host.username;
  homeManagerPkgs = import ../../pkgs pkgs;
  ticketPackage = homeManagerPkgs.ssh-ticket;
  issuer = osConfig.host.ssh.tickets.issuer;
  ticketStateDir = "${config.xdg.stateHome}/ssh-ticket";
  ticketKeyPath = "${config.home.homeDirectory}/.ssh/fleet-ticket/id_ed25519";
  caKeyPath = "${config.home.homeDirectory}/.ssh/${issuer.keyName}";
  caSigningArgs = if issuer.useAgent then "--ca-agent" else "--no-ca-agent";
  ticketTargets = map (
    target: target // { principal = "${username}@${target.name}"; }
  ) osConfig.host.ssh.tickets.targets;
  ticketTargetsFile = pkgs.writeText "ssh-ticket-targets.json" (builtins.toJSON ticketTargets);
  ticketHostBlock =
    target:
    let
      patterns = [
        target.name
        "${target.name}.local"
      ];
    in
    {
      name = "ssh-ticket-host-${target.name}";
      value = lib.hm.dag.entryBefore [ "*" ] {
        header = "Host ${lib.concatStringsSep " " patterns}";
        HostName = target.name;
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
      patterns = [
        target.name
        "${target.name}.local"
      ];
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
    ]) ticketTargets
  );
  enabled =
    config.host.hm.env.preset != null
    && osConfig.host.ssh.tickets.trustedCaPublicKeys != [ ]
    && issuer != null;
in
{
  config = lib.mkIf enabled {
    home.packages = [ ticketPackage ];

    home.sessionVariables = {
      SSHT_TARGETS_FILE = "${ticketTargetsFile}";
      SSHT_CA_KEY = caKeyPath;
      SSHT_CA_AGENT = lib.boolToString issuer.useAgent;
    };

    home.file.".ssh/fleet-user-ca.pub" = lib.mkIf issuer.useAgent {
      text = "${issuer.publicKey}\n";
    };

    programs.ssh.settings = ticketKnownHostSettings;
  };
}
