{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  agentLogPath = "/var/log/nix-darwin/xquartz-startx.log";
  daemonLogPath = "/var/log/nix-darwin/xquartz-privileged-startx.log";
in
{
  imports = [
    ./vnc.nix
    ./wayland.nix
  ];

  options.host.remote-control.client = {
    vnc = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    x11 = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    wayland = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
  };

  config = lib.mkIf (config.host.remote-control.client.x11 != null) {
    services.xquartz = {
      enable = true;
      configureSsh = true;
    };

    launchd.agents.xquartz-startx.serviceConfig = {
      StandardOutPath = agentLogPath;
      StandardErrorPath = agentLogPath;
    };

    launchd.daemons.xquartz-privileged-startx.serviceConfig = {
      StandardOutPath = daemonLogPath;
      StandardErrorPath = daemonLogPath;
    };

    system.activationScripts.launchd.text = lib.mkBefore ''
      install -d -m 0755 -o root -g wheel /var/log/nix-darwin
      if [[ ! -e ${lib.escapeShellArg agentLogPath} ]]; then
        install -m 0644 -o ${lib.escapeShellArg username} -g staff /dev/null ${lib.escapeShellArg agentLogPath}
      fi
      chown ${lib.escapeShellArg "${username}:staff"} ${lib.escapeShellArg agentLogPath}
      chmod 0644 ${lib.escapeShellArg agentLogPath}
    '';

    home-manager.users.${username} = {
      programs.remote-control.client.x11 = { };
    };
  };
}
