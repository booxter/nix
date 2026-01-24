{ isVM ? false, pkgs, ... }:
let
  shutdownDelaySeconds = if isVM then 300 else 600;
in
{
  # TODO: rotate this password and migrate to sops-managed secrets.
  environment.etc."nut/upsadmin.pass" = {
    text = "AdmUps1111\n";
    mode = "0600";
  };

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
    enable = true;
    mode = "netclient";
    upsmon.monitor.nas = {
      system = "ASUSTOR-UPS@nas-lab";
      user = "upsadmin";
      passwordFile = "/etc/nut/upsadmin.pass";
      type = "slave";
    };
    upsmon.settings.NOTIFYFLAG = [
      [ "ONBATT" "SYSLOG+EXEC" ]
      [ "ONLINE" "SYSLOG+EXEC" ]
      [ "LOWBATT" "SYSLOG+EXEC" ]
    ];
    schedulerRules = "${pkgs.writeText "upssched.conf" ''
      CMDSCRIPT /etc/nut/upssched-cmd
      PIPEFN /var/state/ups/upssched.pipe
      LOCKFN /var/state/ups/upssched.lock

      AT ONBATT * START-TIMER onbatt ${toString shutdownDelaySeconds}
      AT ONLINE * CANCEL-TIMER onbatt
      AT LOWBATT * EXECUTE lowbatt
    ''}";
  };
}
