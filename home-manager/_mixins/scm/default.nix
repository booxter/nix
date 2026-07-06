{
  config,
  inputs,
  lib,
  pkgs,
  isWork,
  username,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  scmPkgs = import ./pkgs { inherit pkgs; };
  fullName = "Ihar Hrachyshka";
  email = if isWork then "${username}@nvidia.com" else "ihar.hrachyshka@gmail.com";
  sshSigningKeyPath = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
  gitPackage = if isDarwin then pkgs.gitDarwinPrecompose else pkgs.gitFull;
  pushDisabledGitHubRepos = [
    "NixOS/nixpkgs"
    "ovn-kubernetes/ovn-kubernetes"
  ];
  pushDisabledGitHubUrls = builtins.listToAttrs (
    map (repo: {
      name = "file:///dev/null/git-push-disabled/${repo}";
      value.pushInsteadOf = [
        "git@github.com:${repo}.git"
        "https://github.com/${repo}.git"
      ];
    }) pushDisabledGitHubRepos
  );
in
{
  # Git
  programs.git = {
    enable = true;
    # Use regular git on macos for now, due to: https://github.com/NixOS/nixpkgs/issues/208951
    # with a scoped precompose fix until upstream/nixpkgs includes it.
    package = gitPackage;

    ignores = [
      "*.swp"
    ];

    includes = [
      {
        path = "~/.config/git/config-local";
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

      sendemail =
        if isWork then
          {
            confirm = "auto";
            smtpServer = "mail.nvidia.com";
            smtpServerPort = 587;
            smtpEncryption = "tls";
            smtpUser = "${username}@nvidia.com";
          }
        else
          {
            confirm = "auto";
            smtpServer = "smtp.gmail.com";
            smtpServerPort = 587;
            smtpEncryption = "tls";
            smtpUser = "ihar.hrachyshka@gmail.com";
          };

      # remember and repeat identical merges
      rerere.enabled = true;

      # show touched branches first
      branch.sort = "-committerdate";

      fetch = {
        prune = true;
        pruneTags = true;
      };

      url = {
        # Keep GitHub pushes on SSH instead of gh's broad HTTPS OAuth token.
        "git@github.com:".insteadOf = "https://github.com/";
      }
      // pushDisabledGitHubUrls;

      # use mergiraf for merges
      merge.mergiraf = {
        name = "mergiraf";
        driver = "mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P";
      };
      core.attributesfile = "${pkgs.writeText "gitattributes" ''
        *.java merge=mergiraf
        *.rs merge=mergiraf
        *.go merge=mergiraf
        *.js merge=mergiraf
        *.jsx merge=mergiraf
        *.json merge=mergiraf
        *.yml merge=mergiraf
        *.yaml merge=mergiraf
        *.html merge=mergiraf
        *.htm merge=mergiraf
        *.xhtml merge=mergiraf
        *.xml merge=mergiraf
        *.c merge=mergiraf
        *.cc merge=mergiraf
        *.h merge=mergiraf
        *.cpp merge=mergiraf
        *.hpp merge=mergiraf
        *.cs merge=mergiraf
        *.dart merge=mergiraf
      ''}";
    };
  };

  # diff
  programs.diff-so-fancy = {
    enable = true;
    enableGitIntegration = false;
    settings.markEmptyLines = true;
  };

  # GitHub client
  programs.gh = {
    enable = true;
    extensions = with pkgs; [
      gh-poi
    ];
    settings = {
      git_protocol = "ssh";
    };
  };
  programs.gh-dash = {
    # dashboard
    enable = true;
    settings = {
      repoPaths = {
        # look for source code under ~/src
        ":owner/:repo" = "~/src/:repo";
      };
    };
  };

  # Register GitHub as a known host in SSH config
  home.file = {
    ".ssh/config.d/github.com".text = ''
      Host github.com
        Hostname github.com
        HostKeyAlias github.com
        UserKnownHostsFile ~/.ssh/known_hosts.d/github.com
        User git
    '';

    ".ssh/known_hosts.d/github.com".text =
      lib.concatMapStringsSep "\n" readPublicKey [
        ../../../public-keys/hosts/github.com.ed25519.pub
        ../../../public-keys/hosts/github.com.rsa.pub
        ../../../public-keys/hosts/github.com.ecdsa.pub
      ]
      + "\n";
  };

  # Mercurial
  programs.mercurial = {
    enable = true;
    userName = fullName;
    userEmail = email;
    extraConfig = {
      extensions = {
        rebase = "";
      };
    };
  };

  home.packages = with pkgs; [
    # misc git goodies
    git-absorb
    git-prole
    git-pw
    git-review
    glab
    scmPkgs.glab-mr-create
    mergiraf
    tig

    # for nix dev
    nix-output-monitor
    nixpkgs-reviewFull
    nurl
  ];

  # use vim bindings for tig
  home.file = {
    ".tigrc".source = "${inputs.tig}/contrib/vim.tigrc";
  };
}
