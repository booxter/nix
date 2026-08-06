{
  pkgs,
  ...
}:
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
    ./_mixins/builders
  ];

  config = {
    sops.age.keyFile = "/var/lib/sops-nix/key.txt";

    # Some packages that I'd like to have available on managed machines.
    environment.systemPackages = with pkgs; [
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
      sops-tools
      age
      restic
      sops
    ];

    programs.zsh.enable = true;
  };
}
