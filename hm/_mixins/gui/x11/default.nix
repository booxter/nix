{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  guiCfg = osConfig.host.userEnvironment.features.gui;
in
{
  config = lib.mkIf (guiCfg.enable && guiCfg.x11.enable) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = osConfig.host.isDarwin;
            message = "features.gui.x11 is only supported on Darwin.";
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
