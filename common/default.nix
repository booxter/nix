{
  lib,
  pkgs,
  username,
  hostname,
  isLaptop ? false,
  isWork,
  secretDomain,
  isVM,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  canUseBuilders = !isWork && (hostname == "mair" || hostname == "mmini" || hostname == "frame");
  canUseWorkBuilders = isWork && hostname != "nvws";
  workKeys = [
    (readPublicKey ../public-keys/users/jgwxhwdl4x.pub)
    (readPublicKey ../public-keys/users/jgwxhwdl4x-nix-builder.pub)
  ];
  personalKeys = [
    (readPublicKey ../public-keys/users/mmini.pub)
    (readPublicKey ../public-keys/users/mair.pub)
    (readPublicKey ../public-keys/users/frame.pub)
    (readPublicKey ../public-keys/yubikey.pub)
    (readPublicKey ../public-keys/mair-secretive.pub)
  ];

in
{
  imports = [
    ./_mixins/codex
    ./_mixins/internal-https-mtls-client.nix
    ./_mixins/internal-pki
    ./_mixins/nix
    ./_mixins/nixpkgs
    ./_mixins/nixpkgs-review
    ./_mixins/nix-gc
    ./_mixins/nvtop
    ./_mixins/ssh
    ./_mixins/sync-git-mains
    ./_mixins/terminfo
    ./_mixins/yubi.nix
  ]
  ++ lib.optionals (!isWork) [
    ./_mixins/attic
    ./_mixins/flakehub-cache
  ]
  ++ lib.optionals canUseBuilders [
    ./_mixins/community-builders
    ./_mixins/personal-builders
  ]
  ++ lib.optionals canUseWorkBuilders [
    ./_mixins/work-builders
  ];

  options.host.isWork = lib.mkOption {
    type = lib.types.bool;
    default = false;
  };

  options.host.secretDomain = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = "SOPS secret domain selected for this host.";
  };

  options.host.isProxmox = lib.mkOption {
    type = lib.types.bool;
    default = false;
  };

  options.host.isCritical = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this host should avoid frequent unattended reboots.";
  };

  options.host.isLaptop = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this host is intermittently available like a laptop.";
  };

  options.host.dnsName = lib.mkOption {
    type = lib.types.str;
    default = hostname;
  };

  config = {
    networking.hostName = hostname;
    sops.age.keyFile = "/var/lib/sops-nix/key.txt";

    # Some packages that I'd like to have available on managed machines.
    environment.systemPackages =
      with pkgs;
      [
        bind.dnsutils
        coreutils
        dig
        file
        findutils
        gawk
        git
        gnugrep
        gnumake
        gnused
        gzip
        htop
        iftop
        ipcalc
        iperf3
        jq
        lsof
        man-pages
        moreutils
        ngrep
        pstree
        python3
        rclone
        ripgrep
        speedtest-cli
        tcpdump
        tmux
        tree
        unzip
        viddy
        vim
        watch
        yq
        zip
        ipmitool
      ]
      ++ lib.optionals (!isWork && !isVM) [
        whichllm
      ]
      ++ lib.optionals (!isWork) [
        age
        restic
        sops
      ];

    users.users.${username} = {
      openssh.authorizedKeys.keys = if isWork then workKeys else personalKeys;
    };

    programs.zsh.enable = true;
    host.isLaptop = lib.mkDefault isLaptop;
    host.isWork = isWork;
    host.secretDomain = secretDomain;
  };
}
