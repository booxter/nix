{ pkgs, ... }:
{
  imports = [
    ./_mixins/nix
    ./_mixins/ssh
    ./_mixins/terminfo
  ];

  environment.systemPackages = with pkgs; [
    git
  ];
}
