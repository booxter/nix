{
  pkgs,
  isWork,
  username,
  ...
}:
let
  fullName = "Ihar Hrachyshka";
  email = if isWork then "${username}@nvidia.com" else "ihar.hrachyshka@gmail.com";
in
{
  # Git
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;

    userEmail = email;
    userName = fullName;

    ignores = [
      "*.swp"
    ];

    extraConfig = {
      # ovs/ovn
      pw = {
        server = "https://patchwork.ozlabs.org/api/1.2";
        project = "ovn";
      };

      sendemail =
        if isWork then
          {
            confirm = "auto";
            smtpServer = "smtp.office365.com";
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

    # diff
    diff-so-fancy.enable = true;
    diff-so-fancy.markEmptyLines = true;
  };

  # GitHub client
  programs.gh = {
    enable = true;
    extensions = with pkgs; [
      gh-poi
      gh-copilot
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

  # Register GitHub as a known host in SSH config
  home.file = {
    ".ssh/config.d/github.com".text = ''
      Host github.com
        Hostname github.com
        HostKeyAlias github.com
        UserKnownHostsFile ~/.ssh/known_hosts.d/github.com
        User git
    '';

    ".ssh/known_hosts.d/github.com".text = ''
      github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
      github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
      github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    '';
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
