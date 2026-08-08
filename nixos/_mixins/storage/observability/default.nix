{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  diskBays = config.host.storage.diskBays;
  diskBaysEnabled = diskBays != null;
  hbaEnabled = diskBaysEnabled && diskBays.hbaBackend != null;
  mdEnabled = config.boot.swraid.enable;
  exporterEnabled = diskBaysEnabled || mdEnabled;

  atomicFileWrites = pkgs.python3Packages.callPackage ../../../../pkgs/atomic-file-writes { };
  package = pkgs.callPackage ./package { inherit atomicFileWrites; };
  textfileDir = config.host.observability.nodeExporter.textfile.directory;
  bayMapName = "disk-bay-map.json";
  bayMapPath = "/etc/${bayMapName}";
  diskBayExportCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' package "storage-disk-bay-metrics")
    "--bay-map"
    bayMapPath
    "--output-file"
    "${textfileDir}/disk-bays.prom"
  ];
  hbaExportCommand = lib.escapeShellArgs [
    (lib.getExe package)
    "--bay-map"
    bayMapPath
    "--output-file"
    "${textfileDir}/hba.prom"
  ];
  exporter =
    {
      command,
      description,
      name,
      onBootSec,
      wantedBy ? [ ],
    }:
    {
      systemd.services.${name} = {
        inherit description wantedBy;
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = command;
        };
      };

      systemd.timers.${name} = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = onBootSec;
          OnUnitActiveSec = "1min";
          Unit = "${name}.service";
        };
      };
    };
in
{
  config = lib.mkMerge [
    (lib.mkIf exporterEnabled {
      host.observability.nodeExporter.textfile.enable = true;
      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
      ];
    })

    (lib.mkIf diskBaysEnabled (
      lib.mkMerge [
        {
          environment.etc.${bayMapName}.text = builtins.toJSON diskBays.disks;
        }
        (exporter {
          command = diskBayExportCommand;
          description = "Export disk bay mapping for node exporter";
          name = "storage-disk-bay-export";
          onBootSec = "30s";
          wantedBy = [ "multi-user.target" ];
        })
      ]
    ))

    (lib.mkIf hbaEnabled (exporter {
      command = hbaExportCommand;
      description = "Export HBA metrics for node exporter";
      name = "storage-hba-export";
      onBootSec = "45s";
    }))

    (lib.mkIf mdEnabled (
      lib.mkMerge [
        {
          # node_exporter 1.10.x cannot parse md raid_disks values like
          # "11 (10)" during reshape. The custom textfile exporter retains md
          # visibility without the broken built-in collector.
          services.prometheus.exporters.node.extraFlags = [ "--no-collector.mdadm" ];
        }
        (exporter {
          command = lib.escapeShellArgs [
            (lib.getExe' package "storage-md-metrics")
            "--output-file"
            "${textfileDir}/md-sync.prom"
          ];
          description = "Export md sync status for node exporter";
          name = "storage-md-export";
          onBootSec = "30s";
        })
      ]
    ))
  ];
}
