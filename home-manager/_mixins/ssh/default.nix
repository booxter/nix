{ lib, pkgs, ... }:
{
  services.ssh-agent.enable = pkgs.stdenv.isLinux;
  # OpenSSH ssh-agent exits with status 2 on SIGTERM in this mode; treat that
  # as a clean stop so short-lived user sessions do not look like failures.
  systemd.user.services.ssh-agent.Service.SuccessExitStatus = lib.mkIf pkgs.stdenv.isLinux 2;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false; # deprecated; suppress warnings

    package = pkgs.openssh_gssapi;

    matchBlocks."*" = {
      # agent forwarding to remotes
      forwardAgent = true;
      addKeysToAgent = "yes";
    };

    includes = [
      # local config
      "config.backup" # prior to home-manager activation
      "config.local" # whatever I may want to add manually
      "~/.ssh/config.d/*"
    ];

    # some servers have a problem with kitty terminfo, be conservative
    extraConfig = ''
      SetEnv TERM=xterm-256color
      WarnWeakCrypto no
    '';
  };
}
