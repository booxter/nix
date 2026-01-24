{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.nut
  ];

  environment.etc."nut/nut.conf".text = ''
    MODE = netclient
  '';

  # TODO: rotate this password and migrate to sops-managed secrets.
  environment.etc."nut/upsmon.conf".text = ''
    MINSUPPLIES 1
    MONITOR FRAME-UPS@frame 1 upsslave upsslave234 slave
    NOTIFYCMD ${pkgs.nut}/bin/upssched
    NOTIFYFLAG ONBATT SYSLOG+EXEC
    NOTIFYFLAG ONLINE SYSLOG+EXEC
    NOTIFYFLAG LOWBATT SYSLOG+EXEC
    RUN_AS_USER root
    SHUTDOWNCMD /sbin/shutdown -h now
  '';

  environment.etc."nut/upssched.conf".text = ''
    CMDSCRIPT /etc/nut/upssched-cmd
    PIPEFN /var/state/ups/upssched.pipe
    LOCKFN /var/state/ups/upssched.lock

    AT ONBATT * START-TIMER onbatt 300
    AT ONLINE * CANCEL-TIMER onbatt
    AT LOWBATT * EXECUTE lowbatt
  '';

  environment.etc."nut/upssched-cmd".text = ''
    #!/bin/sh
    case "$1" in
      onbatt)
        /sbin/shutdown -h now "UPS on battery"
        ;;
      lowbatt)
        /sbin/shutdown -h now "UPS battery low"
        ;;
      *)
        exit 0
        ;;
    esac
  '';

  system.activationScripts.upsmonDirs.text = ''
    mkdir -p /var/state/ups /var/lib/nut
    chmod 700 /var/lib/nut
    chmod 755 /etc/nut/upssched-cmd
  '';

  launchd.daemons.nut-upsmon = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.nut}/sbin/upsmon"
        "-D"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      EnvironmentVariables = {
        NUT_CONFPATH = "/etc/nut";
        NUT_STATEPATH = "/var/lib/nut";
      };
      StandardOutPath = "/var/log/upsmon.log";
      StandardErrorPath = "/var/log/upsmon.log";
    };
  };
}
