{
  config,
  lib,
  osConfig,
  pkgs,
  hostname,
  isWork,
  ...
}:
let
  inherit (osConfig.host) isDarwin isLinux;
  useSecretive = isDarwin && hostname == "mair";
  secretiveSocket = "${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh";
  sshAskpass =
    if isDarwin then
      pkgs.callPackage ./pkgs/ssh-askpass-macos { }
    else
      pkgs.callPackage ./pkgs/ssh-askpass-linux { };
  secretiveAuthSockInit = ''
    if [ -z "$SSH_AUTH_SOCK" -o -z "$SSH_CONNECTION" ]; then
      export SSH_AUTH_SOCK="${secretiveSocket}"
    fi
  '';
in
{
  imports = lib.optionals (!isWork) [ ./ticket-client.nix ];

  config = {
    home.sessionVariables = {
      SSH_ASKPASS = lib.getExe sshAskpass;
      SSH_ASKPASS_REQUIRE = "prefer";
    };

    services.ssh-agent.enable = isLinux;
    systemd.user.services.ssh-agent.Service = lib.mkIf isLinux {
      Environment = [
        "SSH_ASKPASS=${lib.getExe sshAskpass}"
        "SSH_ASKPASS_REQUIRE=force"
      ];
      # OpenSSH ssh-agent exits with status 2 on SIGTERM in this mode; treat that
      # as a clean stop so short-lived user sessions do not look like failures.
      SuccessExitStatus = 2;
    };

    programs.bash = lib.mkIf useSecretive {
      profileExtra = lib.mkOrder 900 secretiveAuthSockInit;
      initExtra = lib.mkOrder 900 secretiveAuthSockInit;
    };

    programs.zsh.envExtra = lib.mkIf useSecretive (lib.mkOrder 900 secretiveAuthSockInit);

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      package = pkgs.openssh;

      settings = {
        "*" = {
          # agent forwarding to remotes
          ForwardAgent = true;
          AddKeysToAgent = if useSecretive then "no" else "yes";
        };
      }
      // lib.optionalAttrs (!isWork) {
        frame-boot = {
          HostName = "frame";
          HostKeyAlias = "frame-initrd";
          User = "root";
          RequestTTY = "force";
        };
        mmini-boot = {
          # FileVault's pre-boot SSH server requires a local account password
          # before the normal host keys and ticket CA are available.
          HostName = "mmini";
          HostKeyAlias = "mmini";
          User = config.home.username;
          PreferredAuthentications = "password";
          PasswordAuthentication = true;
          KbdInteractiveAuthentication = false;
          PubkeyAuthentication = false;
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
        SetEnv TERM=xterm-256color
        WarnWeakCrypto no
      '';
    };
  };
}
