{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.ups;
  serverName = cfg.client.server;
  model = import ../../../common/_mixins/ups/model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  server = if serverName == null then null else model.servers.${serverName} or null;
  siteNetwork = import ../../../common/_lib/site-network.nix { inherit config; };
  monitorName = if serverName == null then "" else serverName;
  monitorPasswordSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    server != null
    && import ../../../common/_mixins/ups/uses-literal-credentials.nix {
      clientRealm = config.host.realm;
      serverRealm = server.realm;
    };
  monitorPassword =
    if useLiteralPassword then "upsslave123" else config.sops.placeholder.${monitorPasswordSecret};
  shutdownDelay = config.host.power.shutdown.delaySeconds;
in
{
  config = lib.mkIf (server != null) {
    environment.systemPackages = [ pkgs.nut ];

    environment.etc."nut/nut.conf".text = ''
      MODE = netclient
    '';

    environment.etc."nut/upsmon.conf".source = config.sops.templates."nut-upsmon.conf".path;

    sops.secrets.${monitorPasswordSecret} = lib.mkIf (!useLiteralPassword) {
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
        MONITOR ${server.ups.server.name}@${siteNetwork.addressFor serverName} 1 upsslave ${monitorPassword} slave
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

      ${
        if shutdownDelay == null then
          ""
        else
          ''
            AT ONBATT * START-TIMER onbatt ${toString shutdownDelay}
            AT ONLINE * CANCEL-TIMER onbatt
          ''
      }
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
      command = lib.escapeShellArgs [
        "${pkgs.nut}/sbin/upsmon"
        "-D"
      ];
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables = {
          NUT_CONFPATH = "/etc/nut";
          NUT_STATEPATH = "/var/lib/nut";
          NUT_QUIET_INIT_UPSNOTIFY = "true";
        };
        StandardOutPath = "/var/log/upsmon.log";
        StandardErrorPath = "/var/log/upsmon.log";
      };
    };
  };
}
