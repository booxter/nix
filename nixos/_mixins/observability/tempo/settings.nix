{
  server = {
    http_listen_address = "127.0.0.1";
    http_listen_port = 3200;
    grpc_listen_address = "127.0.0.1";
    # Loki already uses the shared default of 9095 on the monitoring host.
    grpc_listen_port = 9096;
  };
  distributor.receivers.otlp.protocols.http.endpoint = "127.0.0.1:4319";
  ingester.lifecycler = {
    address = "127.0.0.1";
    ring = {
      kvstore.store = "inmemory";
      replication_factor = 1;
    };
  };
  # This is a disposable diagnostic store, not an archive or an HA backend.
  storage.trace = {
    backend = "local";
    wal.path = "/var/lib/tempo/wal";
    local.path = "/var/lib/tempo/blocks";
  };
  compactor.compaction.block_retention = "336h";
  usage_report.reporting_enabled = false;
}
