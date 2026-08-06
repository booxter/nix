{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.ups.scheduler;
in
{
  options.host.ups.scheduler = {
    enable = lib.mkEnableOption "UPS shutdown scheduling";

    critical = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to wait for a low-battery event before shutting down.";
    };

    shutdownDelaySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds to remain on battery before shutting down.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      # upssched (runs as nutmon) needs to create pipe/lock files here
      "d /run/nut 0770 nutmon nutmon -"
      # upssched writes its pid under NUT_STATEPATH (/var/lib/nut by default)
      "d /var/lib/nut 0750 nutmon nutmon -"
    ];

    environment.etc."nut/upssched-cmd" = {
      mode = "0755";
      text = ''
        #!/bin/sh
        case "$1" in
          onbatt)
            ${pkgs.systemd}/bin/shutdown -h now "UPS on battery"
            ;;
          lowbatt)
            ${pkgs.systemd}/bin/shutdown -h now "UPS battery low"
            ;;
          *)
            exit 0
            ;;
        esac
      '';
    };

    power.ups = {
      upsmon.settings.NOTIFYFLAG = [
        [
          "ONBATT"
          "SYSLOG+EXEC"
        ]
        [
          "ONLINE"
          "SYSLOG+EXEC"
        ]
        [
          "LOWBATT"
          "SYSLOG+EXEC"
        ]
      ];
      schedulerRules = "${pkgs.writeText "upssched.conf" ''
        CMDSCRIPT /etc/nut/upssched-cmd
        PIPEFN /run/nut/upssched.pipe
        LOCKFN /run/nut/upssched.lock
        ${
          if cfg.critical then
            ""
          else
            ''
              AT ONBATT * START-TIMER onbatt ${toString cfg.shutdownDelaySeconds}
              AT ONLINE * CANCEL-TIMER onbatt
            ''
        }
        AT LOWBATT * EXECUTE lowbatt
      ''}";
    };
  };
}
