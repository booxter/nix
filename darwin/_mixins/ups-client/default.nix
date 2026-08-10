{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.ups;
  serverName = cfg.client.server;
  fleetNetwork = import ../../../nixos/_lib/fleet-host-network.nix { inherit config outputs; };
  serverSpec = if serverName == null then null else facts.hosts.nixos.${serverName} or null;
  upsServer = if serverName == null then null else facts.ups.serversByName.${serverName} or null;
  clientCredentialMode = facts.realms.${config.host.realm}.services.ups.credentialMode;
  serverCredentialMode =
    if serverSpec == null then null else facts.realms.${serverSpec.realm}.services.ups.credentialMode;
  monitorName = if serverSpec == null then "" else serverSpec.name;
  monitorPasswordSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    serverSpec != null && (clientCredentialMode == "literal" || serverCredentialMode == "literal");
  monitorPassword =
    if useLiteralPassword then "upsslave123" else config.sops.placeholder.${monitorPasswordSecret};
  shutdownDelay = config.host.power.shutdown.delaySeconds;
in
{
  config = lib.mkMerge [
    {
      assertions = lib.optionals (serverName != null) [
        {
          assertion = serverSpec != null;
          message = "host.ups.client.server must name a NixOS host";
        }
        {
          assertion = builtins.elem serverName facts.ups.servers;
          message = "host.ups.client.server must reference a UPS server declared in facts";
        }
      ];
    }
    (lib.mkIf (serverSpec != null && upsServer != null) {
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
          MONITOR ${upsServer.name}@${fleetNetwork.addressFor serverName} 1 upsslave ${monitorPassword} slave
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
          if cfg.shutdown.critical || shutdownDelay == null then
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
    })
  ];
}
