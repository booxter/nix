{ lib, pkgs, username, ... }: {
  services.git-sync = {
    enable = true;
    repositories = {
      password-store = {
        uri = "git+ssh://booxter@github.com:booxter/pass.git";
        path = "/Users/${username}/.local/share/password-store";
      };
      notes = {
        uri = "git+ssh://booxter@github.com:booxter/notes.git";
        path = "/Users/${username}/notes";
        interval = 300;
      };
      weechat-config = {
        uri = "git+ssh://booxter@github.com:booxter/weechat-config.git";
        path = "/Users/${username}/.config/weechat";
      };
      doom-config = {
        uri = "git+ssh://booxter@github.com:booxter/doom.git";
        path = "/Users/${username}/.config/doom";
      };
      gmailctl-private-config = {
        uri = "git+ssh://booxter@github.com:booxter/gmailctl-private-config.git";
        path = "/Users/${username}/.gmailctl";
      };
      gmailctl-work-config = {
        uri = "git+ssh://booxter@github.com:booxter/gmailctl-work-config.git";
        path = "/Users/${username}/.gmailctl-rh";
      };
      priv-bin = {
        uri = "git+ssh://booxter@github.com:booxter/dotfiles.git";
        path = "/Users/${username}/.priv-bin";
      };
    };
  };
  home.activation = {
    notes = import ./git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/notes";
      destdir = "~/notes";
    };
    pass = import ./git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/pass";
      destdir = "~/.local/share/password-store";
    };
    weechat-config = import ./git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/weechat-config";
      destdir = "~/.config/weechat";
    };
    gmailctl-private-config = import ./git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/gmailctl-private-config";
      destdir = "~/.gmailctl";
    };
    gmailctl-work-config = import ./git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/gmailctl-work-config";
      destdir = "~/.gmailctl-rh";
    };
  };
}
