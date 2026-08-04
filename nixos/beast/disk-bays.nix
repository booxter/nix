{
  beastPkgs,
  lib,
  utils,
  ...
}:
let
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  diskBayMappings = [
    {
      bay = "1";
      row = "1";
      col = "1";
      serial = "ZYD01W48";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "3";
      row = "3";
      col = "1";
      serial = "ZYD0CASB";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "5";
      row = "5";
      col = "1";
      serial = "ZYD05Z4J";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "6";
      row = "1";
      col = "2";
      serial = "ZYD041CP";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "7";
      row = "2";
      col = "2";
      serial = "ZXA0RKFF";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "9";
      row = "4";
      col = "2";
      serial = "ZXA0B5K4";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "10";
      row = "5";
      col = "2";
      serial = "ZXA0FFNN";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "11";
      row = "1";
      col = "3";
      serial = "ZYD01W92";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "12";
      row = "2";
      col = "3";
      serial = "ZXA0GW38";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "13";
      row = "3";
      col = "3";
      serial = "ZYD02EQQ";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "15";
      row = "5";
      col = "3";
      serial = "ZXA0ENE4";
      model = "ST24000NM000C-3WD103";
    }
  ];
  exportCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.storage-observability "beast-disk-bay-metrics")
    "--bay-map"
    "/etc/beast-hba-bay-map.json"
    "--output-file"
    "${textfileDir}/disk-bays.prom"
  ];
in
{
  environment.etc."beast-hba-bay-map.json".text = builtins.toJSON diskBayMappings;

  systemd.services.beast-disk-bay-export = {
    description = "Export beast disk bay mapping for node exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = exportCommand;
    };
  };

  systemd.timers.beast-disk-bay-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "1min";
      Unit = "beast-disk-bay-export.service";
    };
  };
}
