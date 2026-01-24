{
  pkgs,
  shutdownDelaySeconds ? null,
  isCriticalNode ? false,
}:
{
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
      PIPEFN /var/state/ups/upssched.pipe
      LOCKFN /var/state/ups/upssched.lock
      ${
        if isCriticalNode then
          ""
        else
          ''
            AT ONBATT * START-TIMER onbatt ${toString shutdownDelaySeconds}
            AT ONLINE * CANCEL-TIMER onbatt
          ''
      }
      AT LOWBATT * EXECUTE lowbatt
    ''}";
  };
}
