{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.xquartz;
  displayInit = ''
    _xquartz_set_display() {
      if [ -n "''${DISPLAY:-}" ]; then
        return
      fi

      local display
      display="$(
        /bin/launchctl print "gui/$(/usr/bin/id -u)/org.nixos.xquartz.startx" 2>/dev/null \
          | /usr/bin/awk '
              /"org\.nixos\.xquartz:0" = \{/ { in_socket = 1; next }
              in_socket && /^[[:space:]]*path = / { print $3; exit }
              in_socket && /^[[:space:]]*\}/ { in_socket = 0 }
            '
      )"

      if [ -S "$display" ]; then
        export DISPLAY="$display"
      fi
    }

    _xquartz_set_display
    unset -f _xquartz_set_display
  '';
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

        programs.bash = {
          profileExtra = lib.mkOrder 900 displayInit;
          initExtra = lib.mkOrder 900 displayInit;
        };

        programs.zsh.envExtra = lib.mkOrder 900 displayInit;
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
