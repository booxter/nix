{ pkgs, ... }:
{
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
  ];

  programs.zsh.enable = true;
}
