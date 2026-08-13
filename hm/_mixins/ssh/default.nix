{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin isLinux;
  enabled = osConfig.host.userEnvironment.features.ssh.enable;
  sshAskpass =
    if isDarwin then
      pkgs.callPackage ./pkgs/ssh-askpass-macos { }
    else
      pkgs.callPackage ./pkgs/ssh-askpass-linux { };
  preBootTargets = builtins.filter (
    target: target.realm == osConfig.host.realm && target.hostName != osConfig.networking.hostName
  ) osConfig.host.ssh.preBoot.targets;
  preBootSettings = builtins.listToAttrs (
    map (target: {
      name = target.alias;
      value = {
        # FileVault's pre-boot SSH server requires a local account password
        # before the normal host keys and ticket CA are available.
        HostName = target.hostName;
        HostKeyAlias = target.hostName;
        User = config.home.username;
        PreferredAuthentications = "password";
        PasswordAuthentication = true;
        KbdInteractiveAuthentication = false;
        PubkeyAuthentication = false;
      };
    }) preBootTargets
  );
in
{
  imports = [
    ./credentials.nix
    ./known-hosts.nix
    ./ticket-client.nix
  ];

  config = lib.mkIf enabled {
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

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      package = pkgs.openssh;

      settings = {
        "*" = {
          # agent forwarding to remotes
          ForwardAgent = true;
        };
      }
      // preBootSettings;

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
