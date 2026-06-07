{
  config,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  useSecretive = pkgs.stdenv.isDarwin && !isWork;
  secretiveSocket = "${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh";
in
{
  services.ssh-agent.enable = pkgs.stdenv.isLinux;
  # OpenSSH ssh-agent exits with status 2 on SIGTERM in this mode; treat that
  # as a clean stop so short-lived user sessions do not look like failures.
  systemd.user.services.ssh-agent.Service.SuccessExitStatus = lib.mkIf pkgs.stdenv.isLinux 2;

  home.packages = lib.optionals useSecretive [
    pkgs.secretive
  ];

  programs.zsh.envExtra = lib.mkIf useSecretive (
    lib.mkOrder 900 ''
      if [ -z "$SSH_AUTH_SOCK" -o -z "$SSH_CONNECTION" ]; then
        export SSH_AUTH_SOCK="${secretiveSocket}"
      fi
    ''
  );

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    package = pkgs.openssh_gssapi;

    # TODO(home-manager release-26.05): switch to programs.ssh.settings once we
    # no longer need compatibility with older home-manager, where matchBlocks
    # is still the active interface.
    matchBlocks."*" = {
      # agent forwarding to remotes
      forwardAgent = true;
      addKeysToAgent = if useSecretive then "no" else "yes";
    };

    includes = [
      # local config
      "config.backup" # prior to home-manager activation
      "config.local" # whatever I may want to add manually
      "~/.ssh/config.d/*"
    ];

    # some servers have a problem with kitty terminfo, be conservative
    extraConfig = ''
      # Work around Home Manager issue #9362: Darwin git-sync launchd jobs may
      # use /usr/bin/ssh, which does not understand every option supported by
      # the Nix-provided OpenSSH in interactive shells.
      IgnoreUnknown WarnWeakCrypto
      SetEnv TERM=xterm-256color
      WarnWeakCrypto no
    '';
  };
}
