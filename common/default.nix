{
  pkgs,
  username,
  hostname,
  isWork,
  ...
}:
{
  imports = [
    ./_mixins/nix
    ./_mixins/nix-gc
    ./_mixins/ssh
    ./_mixins/terminfo
  ];

  networking.hostName = hostname;
  services.tailscale.enable = !isWork;

  # Some packages that I'd like to have available on all my machines.
  environment.systemPackages = with pkgs; [
    bind.dnsutils
    coreutils
    dig
    file
    findutils
    htop
    git
    gnugrep
    gnumake
    gnused
    gzip
    ipcalc
    man-pages
    moreutils
    ngrep
    procps
    pstree
    speedtest-cli
    tcpdump
    tmux
    tree
    unzip
    viddy
    vim
    watch
    zip
  ];

  users.users.${username} = {
    # TODO: separate authorizations between private and non-private VMs; read keys from files
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0X50YNCxMOfuSwc5F/O0lvaRVDkxW4BA94XWz5ovBq" # tab
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan" # mmini
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHt25mSiJLQjx2JECMuhTZEV6rlrOYk3CT2cUEdXAoYs ihrachyshka@ihrachyshka-mlt" # mlt
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBhNnNyDsIzKgNgiIfdHp4LORT+elGraPwcueuiRjk3 ihrachyshka@mair" # mair
    ];
  };

  programs.zsh.enable = true;

  # TODO: move elsewhere
  # TODO: Adopt secrets management
  # /root/.config/attic/config.toml:

  # default-server = "local"
  # [servers.local]
  # endpoint = "http://prox-cachevm:8080"
  # token = "PASTE_PUSH_TOKEN_HERE"

  # Hook script
  nix.settings.post-build-hook = "${pkgs.writeShellScriptBin "attic-push-hook" ''
    exec ${pkgs.attic-client}/bin/attic push default $OUT_PATHS
  ''}/bin/attic-push-hook";
}
