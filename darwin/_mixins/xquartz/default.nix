{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Local copy of nix-darwin PR #1864, with this repository's launchd logging.
  cfg = config.services.xquartz;
  username = config.host.username;
  agentLogPath = "/var/log/nix-darwin/xquartz-startx.log";
  daemonLogPath = "/var/log/nix-darwin/xquartz-privileged-startx.log";
in
{
  options.services.xquartz = {
    enable = lib.mkEnableOption "XQuartz";

    package = lib.mkPackageOption pkgs "xquartz" { };

    configureSsh = lib.mkEnableOption "OpenSSH client integration for X11 forwarding";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        launchd.agents.xquartz-startx = {
          command = lib.escapeShellArgs [
            "${cfg.package}/libexec/launchd_startx"
            "${cfg.package}/bin/startx"
            "--"
            "${cfg.package}/bin/Xquartz"
          ];
          serviceConfig = {
            Label = "org.nixos.xquartz.startx";
            Sockets."org.nixos.xquartz:0".SecureSocketWithKey = "DISPLAY";
            # xinit uses vproc_transaction_begin while the X11 session runs.
            EnableTransactions = true;
            StandardOutPath = agentLogPath;
            StandardErrorPath = agentLogPath;
          };
        };

        launchd.daemons.xquartz-privileged-startx = {
          command = lib.escapeShellArgs [
            "${cfg.package}/libexec/privileged_startx"
            "-d"
            "${cfg.package}/etc/X11/xinit/privileged_startx.d"
          ];
          serviceConfig = {
            Label = "org.nixos.xquartz.privileged_startx";
            MachServices."org.nixos.xquartz.privileged_startx" = true;
            StandardOutPath = daemonLogPath;
            StandardErrorPath = daemonLogPath;
          };
        };

        system.activationScripts.launchd.text = lib.mkBefore ''
          install -d -m 0755 -o root -g wheel /var/log/nix-darwin
          if [[ ! -e ${lib.escapeShellArg agentLogPath} ]]; then
            install -m 0644 -o ${lib.escapeShellArg username} -g staff /dev/null ${lib.escapeShellArg agentLogPath}
          fi
          chown ${lib.escapeShellArg "${username}:staff"} ${lib.escapeShellArg agentLogPath}
          chmod 0644 ${lib.escapeShellArg agentLogPath}
        '';
      }

      (lib.mkIf cfg.configureSsh {
        programs.ssh.extraConfig = lib.mkAfter ''
          XAuthLocation ${lib.getExe pkgs.xauth}
        '';
      })
    ]
  );
}
