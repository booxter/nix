{
  config,
  lib,
  pkgs,
  hostSpecName,
  isWork,
  ...
}:
let
  useSecretive = pkgs.stdenv.isDarwin && hostSpecName == "mair";
  secretiveSocket = "${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh";
  sshAskpass = pkgs.writeShellApplication {
    name = "ssh-askpass-macos";
    text = builtins.readFile ./ssh-askpass-macos.sh;
  };
  secretiveAuthSockInit = ''
    if [ -z "$SSH_AUTH_SOCK" -o -z "$SSH_CONNECTION" ]; then
      export SSH_AUTH_SOCK="${secretiveSocket}"
    fi
  '';
in
{
  imports = lib.optionals (!isWork) [ ./ticket-client.nix ];

  config = {
    home.sessionVariables = lib.mkIf pkgs.stdenv.isDarwin {
      SSH_ASKPASS = lib.getExe sshAskpass;
    };

    services.ssh-agent.enable = pkgs.stdenv.isLinux;
    # OpenSSH ssh-agent exits with status 2 on SIGTERM in this mode; treat that
    # as a clean stop so short-lived user sessions do not look like failures.
    systemd.user.services.ssh-agent.Service.SuccessExitStatus = lib.mkIf pkgs.stdenv.isLinux 2;

    programs.bash = lib.mkIf useSecretive {
      profileExtra = lib.mkOrder 900 secretiveAuthSockInit;
      initExtra = lib.mkOrder 900 secretiveAuthSockInit;
    };

    programs.zsh.envExtra = lib.mkIf useSecretive (lib.mkOrder 900 secretiveAuthSockInit);

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      package = pkgs.openssh_gssapi;

      settings = {
        "*" = {
          # agent forwarding to remotes
          ForwardAgent = true;
          AddKeysToAgent = if useSecretive then "no" else "yes";
        };
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
  };
}
