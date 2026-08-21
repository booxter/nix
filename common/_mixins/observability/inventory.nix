{
  config,
  lib,
  ...
}:
let
  cfg = config.host.observability;
  hostName = config.networking.hostName;
  machine = cfg.inventory.machine;
  services = config.host.web.services or { };
  gpuVendor = config.host.hardware.gpu.vendor or null;
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
      backupServer = lib.mkOption { type = lib.types.bool; };
    };
  };
in
{
  options.host.observability.inventory = {
    machine = {
      hypervisor = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
      };
      virtual = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
      };
    };

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
              host_builder = lib.boolToString (config.host.nix.builder != null);
              host_hypervisor = lib.boolToString machine.hypervisor;
              host_laptop = lib.boolToString config.host.hardware.isLaptop;
              host_network_source = if machine.hypervisor then "classified" else "node";
              host_class = if machine.virtual then "virtual" else "hardware";
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
            virtual = machine.virtual;
            builder = config.host.nix.builder != null;
            hypervisor = machine.hypervisor;
            inherit gpuVendor;
            services = builtins.attrNames services;
            diskBays =
              if diskBays == null then
                null
              else
                {
                  inherit (diskBays) columns rows;
                };
            backupServer = (config.host.backups.server or null) != null;
          }
        else
          null;
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
