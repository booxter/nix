{ ... }:
let
  lokiPort = 3100;
  retentionDays = 365;
  retentionHours = retentionDays * 24;
  lokiRetention = "${toString retentionHours}h";
in
{
  host.internalHttps.services.loki = {
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
}
