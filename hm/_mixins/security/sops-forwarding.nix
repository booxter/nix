{
  config,
  fleetInventory,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  identity = osConfig.host.security.secrets.operator.ageIdentity;
  username = config.home.username;
  socketDirectory = "${config.home.homeDirectory}/.ssh/sops";
  localSocket = "${socketDirectory}/local.sock";
  logPath = "${config.home.homeDirectory}/Library/Logs/nix-darwin-private/sops-keyservice.log";
  realmsByHost = lib.mapAttrs (_: host: host.realm) fleetInventory.hosts;
  sopsTools = import ../../../apps/sops/package.nix { inherit pkgs realmsByHost; };
  sops = pkgs.callPackage ../../../pkgs/sops-keyservice { };
  askpass = pkgs.callPackage (
    if isDarwin then ../ssh/pkgs/ssh-askpass-macos else ../ssh/pkgs/ssh-askpass-linux
  ) { };
  serviceEnvironment = {
    SOPS_AGE_KEY_FILE = identity.path;
    SOPS_AGE_ASKPASS = lib.getExe askpass;
    # Serve only the configured hardware identity, not conventional software
    # identities that SOPS would otherwise also discover in the user's home.
    SOPS_AGE_SSH_PRIVATE_KEY_FILE = "/dev/null";
    XDG_CONFIG_HOME = "${socketDirectory}/keyservice-config";
    PATH = lib.makeBinPath [
      pkgs.age-plugin-se
      pkgs.age-plugin-yubikey
    ];
  };
  service = pkgs.writeShellScript "sops-keyservice" ''
    umask 077
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg socketDirectory}
    ${pkgs.coreutils}/bin/chmod 700 ${lib.escapeShellArg socketDirectory}
    ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg localSocket}
    exec ${sops}/bin/sops keyservice --network unix --address ${lib.escapeShellArg localSocket}
  '';
  ssh = pkgs.symlinkJoin {
    name = "openssh-with-sops";
    paths = [
      pkgs.openssh
      pkgs.openssh.man
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm "$out/bin/ssh"
      makeWrapper ${sopsTools}/bin/sops-ssh "$out/bin/ssh" \
        --add-flags ${
          lib.escapeShellArg (
            "--ssh ${pkgs.openssh}/bin/ssh"
            + " --forwarding-config ${forwardingConfig}"
            + lib.optionalString (identity != null) " --local-socket ${localSocket}"
            + " --"
          )
        }
    '';
    meta = removeAttrs pkgs.openssh.meta [ "outputsToInstall" ];
  };
  targets = lib.filterAttrs (_: host: host.realm == osConfig.host.realm) fleetInventory.hosts;
  targetBlock =
    _: host:
    let
      remoteHome = if host.platform == "darwin" then "/Users/${username}" else "/home/${username}";
      remoteSocket = "${remoteHome}/.ssh/sops/\${SOPS_SSH_CONNECTION}.sock";
    in
    ''
      Match originalhost ${lib.concatStringsSep "," host.ssh.knownHostNames} user ${username}
        RemoteForward ${remoteSocket} ''${SOPS_SSH_SOURCE_SOCKET}
        SetEnv SOPS_KEYSERVICE=unix://${remoteSocket} SOPS_ENABLE_LOCAL_KEYSERVICE=false
        ControlMaster no
        ControlPath none
        ExitOnForwardFailure yes
    '';
  # OpenSSH expands forwarding variables even in inactive Match blocks. Keep
  # these directives out of the ordinary config used by Git and unwrapped SSH.
  # Only the wrapper selects this file, after supplying both variables.
  forwardingConfig = pkgs.writeText "sops-ssh-config" ''
    ${lib.concatStrings (lib.mapAttrsToList targetBlock targets)}
    Match all
      Include ~/.ssh/config
      Include /etc/ssh/ssh_config
  '';
in
{
  # Unix socket permissions are not enforced on every platform. Protect the
  # containing directory too, including on hosts that only receive forwarding.
  home.activation.sopsSockets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg socketDirectory}
  '';

  programs.ssh = lib.mkIf config.host.hm.env.roles.developer {
    package = ssh;
  };

  systemd.user.services.sops-keyservice = lib.mkIf (identity != null && isLinux) {
    Unit = {
      Description = "SOPS hardware key service";
      After = [ "graphical-session-pre.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = toString service;
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") serviceEnvironment;
      UMask = "0077";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  launchd.agents.sops-keyservice = lib.mkIf (identity != null && isDarwin) {
    enable = true;
    config = {
      ProgramArguments = [ (toString service) ];
      EnvironmentVariables = serviceEnvironment;
      RunAtLoad = true;
      KeepAlive = true;
      LimitLoadToSessionType = "Aqua";
      ProcessType = "Interactive";
      StandardOutPath = logPath;
      StandardErrorPath = logPath;
    };
  };
}
