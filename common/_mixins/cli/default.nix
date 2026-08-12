{
  config,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages =
    lib.optionals config.host.userEnvironment.features.shell.enable (
      with pkgs;
      [
        coreutils
        file
        findutils
        gawk
        git
        gnugrep
        gnumake
        gnused
        gzip
        htop
        jq
        lsof
        man-pages
        moreutils
        pstree
        python3
        rclone
        ripgrep
        sqlite
        tmux
        tree
        unzip
        viddy
        vim
        watch
        yq
        zip
      ]
    )
    ++ lib.optionals config.host.userEnvironment.features.net.enable (
      with pkgs;
      [
        bind.dnsutils
        dig
        iftop
        ipcalc
        iperf3
        ipmitool
        ngrep
        speedtest-cli
        tcpdump
      ]
    );

  programs.zsh.enable = config.host.userEnvironment.features.shell.enable;
}
