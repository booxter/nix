{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.xquartz;
  xquartz = pkgs.xquartz;
  logPath = "${config.home.homeDirectory}/Library/Logs/nix-darwin/xquartz-startx.log";
in
{
  options.host.hm.xquartz.enable = lib.mkEnableOption "XQuartz desktop integration";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = osConfig.nixpkgs.hostPlatform.isDarwin;
            message = "host.hm.xquartz is only supported on Darwin.";
          }
        ];

        home.packages = with pkgs; [
          xquartz
          xauth
          xdpyinfo
          xeyes
          xprop
          xterm
          xwininfo
        ];

        launchd.agents.xquartz-startx = {
          enable = true;
          config = {
            Label = "org.nixos.xquartz.startx";
            ProgramArguments = [
              "${xquartz}/libexec/launchd_startx"
              "${xquartz}/bin/startx"
              "--"
              "${xquartz}/bin/Xquartz"
            ];
            # XQuartz expects launchd to allocate DISPLAY as this socket name; X11.bin
            # derives the org.nixos.xquartz prefix from the bundle identifier.
            Sockets."org.nixos.xquartz:0".SecureSocketWithKey = "DISPLAY";
            ServiceIPC = true;
            EnableTransactions = true;
            StandardOutPath = logPath;
            StandardErrorPath = logPath;
          };
        };
      }
      {
        programs.ssh.extraConfig = lib.mkAfter ''
          XAuthLocation ${lib.getExe pkgs.xauth}
        '';
      }
      (lib.mkIf (config.programs.aerospace.enable && config.host.hm.aerospace.x11.enable) {
        programs.aerospace.settings.on-window-detected = lib.mkBefore [
          # XQuartz windows manage their own geometry better outside the tiling tree.
          {
            "if" = "test %{app-bundle-id} = org.nixos.xquartz.X11";
            run = [ "layout floating" ];
          }
        ];
      })
    ]
  );
}
