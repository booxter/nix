{
  lib,
  config,
  pkgs,
  ...
}:
{

  services.git-sync =
    let
      homeDir = config.home.homeDirectory;
    in
    {
      enable = true;
      repositories = {
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
    };

  home.activation =
    let
      git-sync-repo =
        { gh-repo, destdir }:
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          GIT_SSH_COMMAND=${lib.getExe pkgs.openssh} ${lib.getExe pkgs.git} clone git@github.com:${gh-repo}.git ${destdir} || true
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
