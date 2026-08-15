{ config, lib, ... }:
let
  cfg = config.host.observability.loki.server;
  serverEnabled = config.host.observability.server != null;
in
{
  options.host.observability.loki.server = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      readOnly = true;
      internal = true;
      description = "Loopback Loki HTTP port.";
    };

  };

  config = lib.mkIf serverEnabled {
    host.web.services.loki = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      internal = {
        clientAuth = "mtls";
        locationExtraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
        '';
      };
    };

    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = cfg.port;
        };
        common = {
          path_prefix = "/var/lib/loki";
          replication_factor = 1;
          ring.kvstore.store = "inmemory";
        };
        schema_config.configs = [
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
        storage_config.filesystem.directory = "/var/lib/loki/chunks";
        limits_config.retention_period = "8760h";
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
  };
}
