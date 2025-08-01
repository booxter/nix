{ pkgs, hostname, ... }:
{
  imports = [
    ./_mixins/nix
    ./_mixins/ssh
    ./_mixins/terminfo
  ];

  networking.hostName = hostname;

  environment.systemPackages = with pkgs; [
    git
  ];
}
