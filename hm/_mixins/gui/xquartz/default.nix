{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  config = lib.mkIf (osConfig.nixpkgs.hostPlatform.isDarwin && osConfig.services.xquartz.enable) (
    lib.mkMerge [
      {
        home.packages = with pkgs; [
          xauth
          xdpyinfo
          xeyes
          xprop
          xterm
          xwininfo
        ];
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
