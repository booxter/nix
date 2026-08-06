{ pkgs, ... }:
{
  programs.gpg = {
    enable = true;
  };
  services.gpg-agent = {
    enable = true;
    enableSshSupport = false; # it's not 1:1 compatible and can mess output of `ssh-add -l`.
    enableZshIntegration = true;
    pinentry.package = pkgs.pinentry-tty;
  };
}
