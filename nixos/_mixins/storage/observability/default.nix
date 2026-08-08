{
  config,
  hostInventory,
  hostSpec,
  lib,
  pkgs,
  utils,
  ...
}:
let
  hostStorage = hostInventory.storage.hosts.${hostSpec.name} or { };
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
  options.host.storage.diskBays = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          hbaBackend = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "storcli" ]);
            default = null;
            description = "HBA metrics backend for these disk bays.";
          };
          rows = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Number of physical disk-bay rows.";
          };
          disks = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  bay = lib.mkOption { type = lib.types.str; };
                  row = lib.mkOption { type = lib.types.str; };
                  col = lib.mkOption { type = lib.types.str; };
                  serial = lib.mkOption { type = lib.types.str; };
                  model = lib.mkOption { type = lib.types.str; };
                  media = lib.mkOption {
                    type = lib.types.enum [
                      "hdd"
                      "ssd"
                    ];
                    description = "Storage medium installed in this bay.";
                  };
                  transport = lib.mkOption {
                    type = lib.types.enum [
                      "nvme"
                      "sas"
                      "sata"
                    ];
                    description = "Physical transport used by this disk.";
                  };
                };
              }
            );
            description = "Installed disks mapped to physical chassis bays.";
          };
          raidSets = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  implementation = lib.mkOption {
                    type = lib.types.enum [ "md" ];
                    description = "Software implementation managing this RAID set.";
                  };
                  level = lib.mkOption {
                    type = lib.types.enum [
                      0
                      1
                      4
                      5
                      6
                      10
                    ];
                    description = "RAID level used by this set.";
                  };
                  memberBays = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    description = "Physical bays containing this RAID set's members.";
                  };
                  volume = lib.mkOption {
                    type = lib.types.str;
                    description = "Logical storage volume backed by this RAID set.";
                  };
                };
              }
            );
            default = { };
            description = "RAID sets assembled from disks in these bays.";
          };
        };
      }
    );
    default = if config.host.storage.useInventory then hostStorage.diskBays or null else null;
    readOnly = true;
    internal = true;
    description = "Physical disk-bay inventory for this host.";
  };

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
