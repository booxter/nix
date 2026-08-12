{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.xquartz;
in
{
  options.host.hm.xquartz.enable = lib.mkEnableOption "XQuartz desktop integration";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = osConfig.host.isDarwin;
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
