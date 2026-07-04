{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.xquartz;
in
{
  options.programs.xquartz = {
    enable = lib.mkEnableOption "XQuartz user integration";

    configureSsh = lib.mkEnableOption "OpenSSH XAuthLocation for XQuartz forwarding";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = pkgs.stdenv.isDarwin;
            message = "`programs.xquartz.enable` is only supported on Darwin.";
          }
        ];

        home.packages = [ pkgs.xquartz ];
      }
      (lib.mkIf cfg.configureSsh {
        programs.ssh.extraConfig = lib.mkAfter ''
          XAuthLocation ${lib.getExe pkgs.xauth}
        '';
      })
      (lib.mkIf config.programs.aerospace.enable {
        programs.aerospace.settings.on-window-detected = lib.mkBefore [
          # XQuartz windows manage their own geometry better outside the tiling tree.
          {
            "if" = {
              app-id = "org.nixos.xquartz.X11";
            };
            run = [ "layout floating" ];
          }
        ];
      })
    ]
  );
}
