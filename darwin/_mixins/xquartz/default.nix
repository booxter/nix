{
  config,
  lib,
  pkgs,
  ...
}:
let
  xquartz = pkgs.xquartz;
  username = config.host.username;
  cfg = config.home-manager.users.${username}.host.hm.xquartz;
  userLogDirectory = "${config.users.users.${username}.home}/Library/Logs/nix-darwin";
in
{
  config = lib.mkIf cfg.enable {
    # XQuartz itself is installed by Home Manager. The launchd jobs still need
    # package-internal helpers under libexec and etc/X11, which Home Manager's
    # profile symlink farm does not expose, so point launchd at the store path.
    launchd.daemons.xquartz-privileged-startx = {
      command = lib.escapeShellArgs [
        "${xquartz}/libexec/privileged_startx"
        "-d"
        "${xquartz}/etc/X11/xinit/privileged_startx.d"
      ];
      serviceConfig = {
        Label = "org.nixos.xquartz.privileged_startx";
        MachServices."org.nixos.xquartz.privileged_startx" = true;
        TimeOut = 120;
        EnableTransactions = true;
        StandardOutPath = "/var/log/nix-darwin/xquartz-privileged-startx.log";
        StandardErrorPath = "/var/log/nix-darwin/xquartz-privileged-startx.log";
      };
    };

    system.activationScripts.launchd.text = lib.mkBefore ''
      install -d -m 0755 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg userLogDirectory}
    '';
  };
}
