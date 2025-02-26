{
  lib,
  pkgs,
  username,
  ...
}:
let
  fullName = "Ihar Hrachyshka";
  email = "ihar.hrachyshka@gmail.com";
in
{
  # Use homebrew or system ssh for git: they support gss.
  home.sessionVariables = lib.optionalAttrs pkgs.stdenv.isDarwin {
    GIT_SSH_COMMAND = if pkgs.stdenv.isDarwin then "/opt/homebrew/bin/ssh" else "/usr/bin/ssh";
  };

  # Git
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;

    userEmail = email;
    userName = fullName;

    ignores = [
      "*.swp"
    ];

    hooks = {
      # TODO: rewrite the hook script use nix
      prepare-commit-msg = ./prepare-commit-msg.sh;
    };

    extraConfig = {
      # ovs/ovn
      pw = {
        server = "https://patchwork.ozlabs.org/api/1.2";
        project = "ovn";
      };

      # use rh smtp for send-email by default
      sendemail = {
        confirm = "auto";
        smtpServer = "smtp.gmail.com";
        smtpServerPort = 587;
        smtpEncryption = "tls";
        smtpUser = "${username}@redhat.com";
      };

      # remember and repeat identical merges
      rerere.enabled = true;

      # show touched branches first
      branch.sort = "-committerdate";

      # use mergigraf for merges
      merge.mergigraf = {
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

    # diff
    diff-so-fancy.enable = true;
    diff-so-fancy.markEmptyLines = true;
  };

  # GitHub client
  programs.gh = {
    enable = true;
    extensions = with pkgs; [
      gh-copilot
      gh-poi
    ];
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

  # Mercurial
  programs.mercurial = {
    enable = true;
    userName = fullName;
    userEmail = email;
  };

  home.packages = with pkgs; [
    arcanist # phabricator client

    # misc git goodies
    git-absorb
    git-prole
    git-pw
    git-review
    mergiraf
    tig

    # for nix dev
    nixpkgs-review
    nurl
  ];

  # use vim bindings for tig
  home.file = {
    ".tigrc".source =
      pkgs.fetchFromGitHub {
        owner = "jonas";
        repo = "tig";
        rev = "c6899e98e10da37e8034e0f0cfd0904091ad34e5";
        sha256 = "sha256-crgIhsXqp6XpyF0vXYJIPpWmfLSCyeXCirWlrRxx/gg=";
      }
      + "/contrib/vim.tigrc";
  };
}
