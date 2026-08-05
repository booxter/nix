{
  config,
  lib,
  pkgs,
  username,
  hostname,
  secretDomain,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  workUserKey = readPublicKey ../public-keys/users/jgwxhwdl4x.pub;
  workKeys = [
    workUserKey
    (readPublicKey ../public-keys/users/jgwxhwdl4x-nix-builder.pub)
  ];
  personalKeys = [
    (readPublicKey ../public-keys/users/mmini.pub)
    (readPublicKey ../public-keys/users/mair.pub)
    (readPublicKey ../public-keys/users/frame.pub)
    (readPublicKey ../public-keys/yubikey.pub)
    (readPublicKey ../public-keys/mair-secretive.pub)
    workUserKey
  ];

in
{
  imports = [
    ./_mixins/codex
    ./_mixins/host.nix
    ./_mixins/internal-https-mtls-client.nix
    ./_mixins/internal-pki
    ./_mixins/nix
    ./_mixins/nixpkgs
    ./_mixins/nixpkgs-review
    ./_mixins/nix-gc
    ./_mixins/ssh
    ./_mixins/stylix
    ./_mixins/terminfo
    ./_mixins/yubi.nix
    ./_mixins/attic
    ./_mixins/flakehub-cache
    ./_mixins/community-builders
    ./_mixins/personal-builders
    ./_mixins/work-builders
  ];

  options.host.isVM = lib.mkOption {
    type = lib.types.bool;
    readOnly = true;
    internal = true;
    description = "Whether this host is a virtual machine.";
  };

  options.host.secretDomain = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = "SOPS secret domain selected for this host.";
  };

  options.host.isCritical = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this host should avoid frequent unattended reboots.";
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
        sqlite
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
      ++ lib.optionals (!config.host.isWork && !config.host.isVM) [
        whichllm
      ]
      ++ lib.optionals config.host.isDesktop [
        sops-tools
      ]
      ++ lib.optionals (!config.host.isWork) [
        age
        restic
        sops
      ];

    users.users.${username} = {
      openssh.authorizedKeys.keys = if config.host.isWork then workKeys else personalKeys;
    };

    programs.zsh.enable = true;
    host.secretDomain = secretDomain;
  };
}
