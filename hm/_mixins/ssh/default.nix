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
