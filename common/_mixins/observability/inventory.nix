{
  config,
  lib,
  ...
}:
let
  cfg = config.host.observability;
  hostName = config.networking.hostName;
  isProxmoxNode = config.host.proxmox.node != null;
  enabledServices = lib.filterAttrs (_: service: service.enable) (config.host.web.services or { });
  gpuVendors = config.host.hardware.gpu.vendors or [ ];
  fileSystems = builtins.attrValues (config.fileSystems or { });
  diskBays = config.host.hardware.storage.diskBays or null;
  dashboardType = lib.types.submodule {
    options = {
      name = lib.mkOption { type = lib.types.nonEmptyStr; };
      platform = lib.mkOption {
        type = lib.types.enum [
          "darwin"
          "linux"
        ];
      };
      virtual = lib.mkOption { type = lib.types.bool; };
      builder = lib.mkOption { type = lib.types.bool; };
      hypervisor = lib.mkOption { type = lib.types.bool; };
      gpuVendor = lib.mkOption { type = with lib.types; nullOr nonEmptyStr; };
      services = lib.mkOption { type = with lib.types; listOf nonEmptyStr; };
      storage = {
        btrfs = lib.mkOption { type = lib.types.bool; };
        diskBays = lib.mkOption {
          type =
            with lib.types;
            nullOr (submodule {
              options = {
                columns = lib.mkOption { type = ints.positive; };
                rows = lib.mkOption { type = ints.positive; };
              };
            });
        };
        nvme = lib.mkOption { type = lib.types.bool; };
      };
      backups = {
        client = lib.mkOption { type = lib.types.bool; };
        server = lib.mkOption { type = lib.types.bool; };
      };
    };
  };
  endpointType = lib.types.submodule {
    options = {
      jobName = lib.mkOption { type = lib.types.nonEmptyStr; };
      path = lib.mkOption { type = lib.types.str; };
      interval = lib.mkOption { type = with lib.types; nullOr str; };
      timeout = lib.mkOption { type = with lib.types; nullOr str; };
      metricRelabelConfigs = lib.mkOption { type = with lib.types; listOf attrs; };
      target = lib.mkOption { type = lib.types.nonEmptyStr; };
      labels = lib.mkOption { type = with lib.types; attrsOf str; };
    };
  };
in
{
  options.host.observability.inventory = {
    realm = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = config.host.realm;
      readOnly = true;
      internal = true;
    };

    node = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            target = lib.mkOption { type = nonEmptyStr; };
            mtls = lib.mkOption { type = bool; };
            labels = lib.mkOption { type = attrsOf str; };
          };
        });
      default =
        if cfg.enable then
          {
            target = "${hostName}:9100";
            mtls = cfg.nodeExporter.mtls.enable;
            labels = {
              availability = if config.host.hardware.isLaptop then "intermittent" else "always";
              component = "node";
              host_builder = lib.boolToString config.host.nix.builder.enable;
              host_hypervisor = lib.boolToString isProxmoxNode;
              host_laptop = lib.boolToString config.host.hardware.isLaptop;
              host_network_charts = lib.boolToString (!isProxmoxNode);
              host_network_source = if isProxmoxNode then "classified" else "node";
              host_class = if config.host.proxmox.guest != null then "virtual" else "hardware";
              host_virtual = lib.boolToString (config.host.proxmox.guest != null);
              instance = hostName;
              realm = config.host.realm;
              scrape_profile = "node";
            };
          }
        else
          null;
      internal = true;
    };

    dashboard = lib.mkOption {
      type = with lib.types; nullOr dashboardType;
      default =
        if cfg.enable then
          {
            name = hostName;
            platform = if config.nixpkgs.hostPlatform.isDarwin then "darwin" else "linux";
            virtual = config.host.proxmox.guest != null;
            builder = config.host.nix.builder.enable;
            hypervisor = isProxmoxNode;
            gpuVendor = if gpuVendors == [ ] then null else lib.head gpuVendors;
            services = builtins.attrNames enabledServices;
            storage = {
              btrfs = builtins.any (fileSystem: (fileSystem.fsType or null) == "btrfs") fileSystems;
              diskBays =
                if diskBays == null then
                  null
                else
                  {
                    inherit (diskBays) columns rows;
                  };
              nvme = false;
            };
            backups = {
              client = (config.host.backups.jobs or { }) != { };
              server = config.host.backups.server.enable or false;
            };
          }
        else
          null;
      internal = true;
    };

    endpoints = lib.mkOption {
      type = lib.types.attrsOf endpointType;
      default = { };
      internal = true;
    };

    blackbox = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            exporter = lib.mkOption { type = nonEmptyStr; };
            scheme = lib.mkOption {
              type = enum [
                "http"
                "https"
              ];
            };
            source = lib.mkOption { type = nonEmptyStr; };
          };
        });
      default = null;
      internal = true;
    };

    proxmox = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            cluster = lib.mkOption { type = nonEmptyStr; };
            realm = lib.mkOption { type = nonEmptyStr; };
            target = lib.mkOption { type = nonEmptyStr; };
            node = lib.mkOption { type = nonEmptyStr; };
            pveTarget = lib.mkOption { type = nonEmptyStr; };
          };
        });
      default = null;
      internal = true;
    };
  };
}
