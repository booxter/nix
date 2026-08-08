{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  shelfmarkCfg = config.services.shelfmark;
  cfg = shelfmarkCfg.ebookConverter;
  booksDir = shelfmarkCfg.environment.EBOOK_CONVERTER_LIBRARY_ROOT;
  mediaDir = shelfmarkCfg.mediaDir;
  mediaLayout = hostInventory.storage.nfs.exports.media.layout;
  mediaGroup = hostInventory.storage.nfs.exports.media.sharedGroup.name;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/ebook-converter.prom";
  ebookConverterCli = pkgs.callPackage ./packages/ebook-converter-cli { };
in
{
  options.services.shelfmark.ebookConverter = {
    enable = lib.mkEnableOption "Shelfmark ebook conversion";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./packages/ebook-converter {
        atomicFileWrites = pkgs.atomic-file-writes;
        inherit ebookConverterCli;
      };
      description = "Package providing Shelfmark ebook conversion.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ebook-converter";
      description = "Directory containing ebook converter state.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = shelfmarkCfg.enable;
        message = "Shelfmark ebook conversion requires Shelfmark on the same host.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0770 shelfmark ${mediaGroup} - -"
      "z ${nodeExporterTextfileDir} 0775 root ${mediaGroup} - -"
    ];

    systemd.services.ebook-converter = {
      description = "Convert library MOBI and AZW3 files to EPUB";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = booksDir;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe cfg.package)
          "watch"
          "--library-root"
          booksDir
          "--lock-root"
          cfg.stateDir
          "--state-file"
          "${cfg.stateDir}/state.json"
          "--metrics-file"
          metricsFile
          "--interval-seconds"
          "30"
          "--settle-seconds"
          "30"
          "--max-attempts"
          "3"
        ];
        Environment = "XDG_CONFIG_HOME=${cfg.stateDir}";
        User = "shelfmark";
        Group = mediaGroup;
        UMask = "0002";
        Restart = "always";
        RestartSec = "10s";
        Nice = 10;
        IOSchedulingClass = "idle";
        CPUQuota = "200%";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        RemoveIPC = true;
        InaccessiblePaths = [
          "${mediaDir}/${mediaLayout.transmission.root}"
          "${mediaDir}/${mediaLayout.sabnzbd.root}"
        ];
        ReadWritePaths = [
          booksDir
          cfg.stateDir
          nodeExporterTextfileDir
        ];
      };
    };
  };
}
