{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.observability.loki.server;
  hostname = config.networking.hostName;
  lokiService = hostInventory.servicesById.loki;
  lokiPort = cfg.port;
  retentionDays = cfg.retentionDays;
  retentionHours = retentionDays * 24;
  lokiRetention = "${toString retentionHours}h";
in
{
  options.host.observability.loki.server = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = lokiService.owner == hostname;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns the Loki service to this host.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "Loopback port on which Loki listens.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Number of days for which Loki retains logs.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.hasAttr lokiService.owner hostInventory.nixosHosts;
          message = "Loki owner '${lokiService.owner}' must be a managed NixOS host";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      host.internalService.services.${lokiService.id} = {
        enable = true;
        upstream = "http://127.0.0.1:${toString lokiPort}";
        mtls.enable = true;
        locationExtraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
        '';
      };

      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = lokiPort;
          };
          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring = {
              kvstore.store = "inmemory";
            };
          };
          schema_config = {
            configs = [
              {
                from = "2024-01-01";
                store = "tsdb";
                object_store = "filesystem";
                schema = "v13";
                index = {
                  prefix = "index_";
                  period = "24h";
                };
              }
            ];
          };
          storage_config = {
            filesystem.directory = "/var/lib/loki/chunks";
          };
          limits_config = {
            retention_period = lokiRetention;
          };
          compactor = {
            working_directory = "/var/lib/loki/retention";
            compaction_interval = "10m";
            retention_enabled = true;
            retention_delete_delay = "2h";
            retention_delete_worker_count = 50;
            delete_request_store = "filesystem";
          };
        };
      };
    })
  ];
}
