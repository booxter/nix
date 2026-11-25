{
  server = {
    http_listen_address = "127.0.0.1";
    http_listen_port = 3200;
    grpc_listen_address = "127.0.0.1";
    # Loki already uses the shared default of 9095 on the monitoring host.
    grpc_listen_port = 9096;
  };
  distributor.receivers.otlp.protocols.http.endpoint = "127.0.0.1:4319";
  live_store = {
    ring = {
      kvstore.store = "inmemory";
      instance_addr = "127.0.0.1";
    };
    partition_ring.kvstore.store = "inmemory";
    wal.path = "/var/lib/tempo/live-store/traces";
    shutdown_marker_dir = "/var/lib/tempo/live-store/shutdown-marker";
  };
  # This is a disposable diagnostic store, not an archive or an HA backend.
  storage.trace = {
    backend = "local";
    wal.path = "/var/lib/tempo/wal";
    local.path = "/var/lib/tempo/blocks";
  };
  backend_scheduler = {
    local_work_path = "/var/lib/tempo/work";
    provider.compaction.compaction.block_retention = "336h";
  };
  backend_worker.compaction.block_retention = "336h";
  usage_report.reporting_enabled = false;
}
