{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin isLinux;
  enabled = config.host.hm.env.roles.developer;
  useDarwinAgent = isDarwin && osConfig.host.ssh.credentials.backend == "yubikey";
  agentLogPath = "${config.home.homeDirectory}/Library/Logs/nix-darwin-private/ssh-agent.log";
  sshAskpass =
    if isDarwin then
      pkgs.callPackage ./pkgs/ssh-askpass-macos { }
    else
      pkgs.callPackage ./pkgs/ssh-askpass-linux { };
  preBootEndpoints = lib.filterAttrs (
    _: endpoint: endpoint.hostName != osConfig.networking.hostName
  ) osConfig.host.ssh.preBoot.endpoints;
  preBootSettings = lib.mapAttrs (
    _: endpoint:
    {
      HostName = endpoint.hostName;
      HostKeyAlias = endpoint.hostKeyAlias;
      User = if endpoint.user == null then config.home.username else endpoint.user;
      RequestTTY = if endpoint.requestTTY then "force" else "no";
    }
    // lib.optionalAttrs (endpoint.authentication == "password") {
      # FileVault's pre-boot SSH server requires a local account password
      # before the normal host keys and ticket CA are available.
      PreferredAuthentications = "password";
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      PubkeyAuthentication = false;
    }
  ) preBootEndpoints;
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

    services.ssh-agent.enable = isLinux || useDarwinAgent;
    systemd.user.services.ssh-agent.Service = lib.mkIf isLinux {
      Environment = [
        "SSH_ASKPASS=${lib.getExe sshAskpass}"
        "SSH_ASKPASS_REQUIRE=force"
      ];
      # OpenSSH ssh-agent exits with status 2 on SIGTERM in this mode; treat that
      # as a clean stop so short-lived user sessions do not look like failures.
      SuccessExitStatus = 2;
    };

    launchd.agents.ssh-agent.config = lib.mkIf useDarwinAgent {
      EnvironmentVariables = {
        SSH_ASKPASS = lib.getExe sshAskpass;
        SSH_ASKPASS_REQUIRE = "force";
      };
      ProcessType = lib.mkForce "Interactive";
      LimitLoadToSessionType = "Aqua";
      StandardOutPath = agentLogPath;
      StandardErrorPath = agentLogPath;
    };

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      package = lib.mkDefault pkgs.openssh;
      settings = preBootSettings;

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
