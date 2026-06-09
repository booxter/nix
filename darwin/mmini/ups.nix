{
  config,
  lib,
  pkgs,
  hostInventory,
  upsShutdownDelaySeconds,
  ...
}:
let
  frameSpec = hostInventory.nixosHostSpecsByName.frame;
  monitorName = frameSpec.name;
  monitorPasswordSecret = "nut/monitors/${monitorName}/password";
in
{
  environment.systemPackages = [
    pkgs.nut
  ];

  environment.etc."nut/nut.conf".text = ''
    MODE = netclient
  '';

  environment.etc."nut/upsmon.conf".source = config.sops.templates."nut-upsmon.conf".path;

  sops.secrets.${monitorPasswordSecret} = {
    owner = "root";
    group = "wheel";
    mode = "0400";
  };

  sops.templates."nut-upsmon.conf" = {
    owner = "root";
    group = "wheel";
    mode = "0400";
    content = ''
      MINSUPPLIES 1
      MONITOR ${hostInventory.toUpsName frameSpec.name}@${
        frameSpec.dnsName or frameSpec.name
      } 1 upsslave ${config.sops.placeholder.${monitorPasswordSecret}} slave
      NOTIFYCMD ${pkgs.nut}/bin/upssched
      NOTIFYFLAG ONBATT SYSLOG+EXEC
      NOTIFYFLAG ONLINE SYSLOG+EXEC
      NOTIFYFLAG LOWBATT SYSLOG+EXEC
      POWERDOWNFLAG /var/lib/nut/upsmon.powerdown
      RUN_AS_USER root
      SHUTDOWNCMD /sbin/shutdown -h now
    '';
  };

  environment.etc."nut/upssched.conf".text = ''
    CMDSCRIPT /etc/nut/upssched-cmd
    PIPEFN /var/lib/nut/upssched.pipe
    LOCKFN /var/lib/nut/upssched.lock

    AT ONBATT * START-TIMER onbatt ${toString upsShutdownDelaySeconds}
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

  system.activationScripts.preActivation.text = lib.mkAfter ''
    if [ -L /etc/nut/upsmon.conf ] && [ ! -e /etc/nut/upsmon.conf ]; then
      rm /etc/nut/upsmon.conf
    fi
  '';

  system.activationScripts.postActivation.text = lib.mkAfter ''
    mkdir -p /var/lib/nut
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
        # Silence upsnotify warning; consider enabling a launchd-capable notifier in NUT if desired.
        NUT_QUIET_INIT_UPSNOTIFY = "true";
      };
      StandardOutPath = "/var/log/upsmon.log";
      StandardErrorPath = "/var/log/upsmon.log";
    };
  };
}
