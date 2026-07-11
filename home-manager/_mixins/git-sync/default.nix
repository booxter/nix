{
  lib,
  config,
  pkgs,
  ...
}:
let
  homeDir = config.home.homeDirectory;
  gitSyncPackage =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.git-sync.override {
        gitMinimal = pkgs.gitMinimalDarwinPrecompose;
      }
    else
      pkgs.git-sync;
  # Non-interactive git-sync jobs use the passwordless id_ed25519 key instead
  # of the YubiKey resident key, which may not be present or touchable.
  gitSyncSsh = pkgs.writeShellApplication {
    name = "git-sync-ssh";
    text = ''
      exec ${lib.getExe pkgs.openssh} \
        -F /dev/null \
        -i ${lib.escapeShellArg "${homeDir}/.ssh/id_ed25519"} \
        -o BatchMode=yes \
        -o HostKeyAlias=github.com \
        -o IdentitiesOnly=yes \
        -o IdentityAgent=none \
        -o KbdInteractiveAuthentication=no \
        -o PasswordAuthentication=no \
        -o PreferredAuthentications=publickey \
        -o UserKnownHostsFile=${lib.escapeShellArg "${homeDir}/.ssh/known_hosts.d/github.com"} \
        "$@"
    '';
  };
  gitSyncSshEnv = {
    GIT_SSH = lib.getExe gitSyncSsh;
    GIT_SSH_COMMAND = lib.getExe gitSyncSsh;
  };
  gitSyncServiceEnvironment = lib.mapAttrsToList (name: value: "${name}=${value}") gitSyncSshEnv;
  gitSyncRepositories = {
    password-store = {
      uri = "git+ssh://booxter@github.com:booxter/pass.git";
      path = "${homeDir}/.local/share/password-store";
    };
    notes = {
      uri = "git+ssh://booxter@github.com:booxter/notes.git";
      path = "${homeDir}/notes";
      interval = 300;
    };
    vault = {
      uri = "git+ssh://booxter@github.com:booxter/vault.git";
      path = "${homeDir}/vault";
      interval = 300;
    };
    gmailctl-config = {
      uri = "git+ssh://booxter@github.com:booxter/gmailctl-private-config.git";
      path = "${homeDir}/.gmailctl";
    };
    # DO NOT SYNC priv-bin
  };
  gitSyncSystemdUnits = lib.mapAttrs' (name: _: {
    name = "git-sync-${name}";
    value = {
      Service.Environment = lib.mkAfter gitSyncServiceEnvironment;
    };
  }) gitSyncRepositories;
  gitSyncLaunchdAgents = lib.mapAttrs' (name: _: {
    name = "git-sync-${name}";
    value = {
      config.EnvironmentVariables = gitSyncSshEnv;
    };
  }) gitSyncRepositories;
in
{

  services.git-sync = {
    enable = true;
    package = gitSyncPackage;
    repositories = gitSyncRepositories;
  };

  systemd.user.services = lib.mkIf (!pkgs.stdenv.hostPlatform.isDarwin) gitSyncSystemdUnits;
  launchd.agents = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin gitSyncLaunchdAgents;

  home.activation =
    let
      git-sync-repo =
        { gh-repo, destdir }:
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          GIT_SSH_COMMAND=${lib.getExe gitSyncSsh} ${lib.getExe pkgs.git} clone git@github.com:${gh-repo}.git ${destdir} || true
          pushd ${destdir} && ${lib.getExe pkgs.git} config --bool branch.master.sync true && ${lib.getExe pkgs.git} config --bool branch.master.syncNewFiles true && popd
        '';
    in
    {
      notes = git-sync-repo {
        gh-repo = "booxter/notes";
        destdir = "~/notes";
      };
      vault = git-sync-repo {
        gh-repo = "booxter/vault";
        destdir = "~/vault";
      };
      pass = git-sync-repo {
        gh-repo = "booxter/pass";
        destdir = "~/.local/share/password-store";
      };
      gmailctl-private-config = git-sync-repo {
        gh-repo = "booxter/gmailctl-private-config";
        destdir = "~/.gmailctl";
      };
      # Activate but don't sync
      priv-bin = git-sync-repo {
        gh-repo = "booxter/dotfiles";
        destdir = "~/.priv-bin";
      };
    };

  home.sessionPath = [
    "$HOME/.priv-bin"
  ];
}
