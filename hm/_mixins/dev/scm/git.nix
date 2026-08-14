{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  scmCfg = devCfg.scm;
  scmPkgs = import ./pkgs { inherit pkgs; };
  inherit (config.host.hm) email fullName;
  sshSigningKeyPath = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
in
lib.mkIf (osConfig.host.userEnvironment.roles.developer.enable && scmCfg.enable) {
  home.shellAliases.g = "git";

  programs.git = {
    ignores = [ "*.swp" ];

    includes = [
      { path = "~/.config/git/config-local"; }
      {
        condition = "gitdir:~/src/nix/";
        contents.user.email = "ihar.hrachyshka@gmail.com";
        contentSuffix = "nix-repo-email";
      }
    ];

    settings = {
      user = {
        inherit email;
        name = fullName;
        signingKey = lib.mkDefault sshSigningKeyPath;
      };

      gpg.format = "ssh";
      commit.gpgSign = true;
      tag.gpgSign = true;

      hook."commit-message-format" = {
        event = "commit-msg";
        command = lib.getExe scmPkgs.check-commit-message;
      };

      # Keep a generic pager for non-diff git commands. diff-so-fancy is only
      # suitable for diff-shaped output and breaks commands like `git grep`
      # when installed as the global core.pager.
      # TODO: Report this integration bug to Home Manager and
      # diff-so-fancy upstream docs. `enableGitIntegration` should not route
      # all git pager traffic through diff-so-fancy.
      core.pager = "${pkgs.less}/bin/less '--tabs=4' -RFX";
      pager = {
        diff = "${pkgs.diff-so-fancy}/bin/diff-so-fancy | ${pkgs.less}/bin/less '--tabs=4' -RFX";
        show = "${pkgs.diff-so-fancy}/bin/diff-so-fancy | ${pkgs.less}/bin/less '--tabs=4' -RFX";
      };

      # ovs/ovn
      pw = {
        server = "https://patchwork.ozlabs.org/api/1.2";
        project = "ovn";
      };

      # remember and repeat identical merges
      rerere.enabled = true;

      # show touched branches first
      branch.sort = "-committerdate";

      fetch = {
        prune = true;
        pruneTags = true;
      };

      push = {
        autoSetupRemote = true;

        # Make explicit force-with-lease pushes reject remote commits that have
        # not first been integrated locally.
        useForceIfIncludes = true;
      };
    };
  };

  programs.diff-so-fancy = {
    enable = true;
    enableGitIntegration = false;
    settings.markEmptyLines = true;
  };

  home.packages = with pkgs; [
    git-absorb
    git-prole
    git-pw
    git-review
  ];
}
