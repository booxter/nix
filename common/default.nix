{
  pkgs,
  username,
  hostname,
  ...
}:
{
  imports = [
    ./_mixins/nix
    ./_mixins/ssh
    ./_mixins/terminfo
  ];

  networking.hostName = hostname;

  # Some packages that I'd like to have available on all my machines.
  environment.systemPackages = with pkgs; [
    git
    gnumake
    tmux
    vim
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
}
