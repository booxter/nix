{
  endpoint,
  caFile,
  certFile,
  keyFile,
}:
let
  paths = import ./paths.nix;
in
''
  otelcol.receiver.otlp "local" {
    grpc {
      endpoint = "${paths.socket}"
      transport = "unix"
      max_recv_msg_size = "4MiB"
    }
    output {
      traces = [otelcol.processor.memory_limiter.traces.input]
    }
  }

  otelcol.processor.memory_limiter "traces" {
    check_interval = "1s"
    limit = "256MiB"
    spike_limit = "64MiB"
    output {
      traces = [otelcol.processor.batch.traces.input]
    }
  }

  otelcol.processor.batch "traces" {
    timeout = "5s"
    send_batch_size = 256
    send_batch_max_size = 512
    output {
      traces = [otelcol.exporter.otlphttp.tempo.input]
    }
  }

  otelcol.exporter.otlphttp "tempo" {
    client {
      endpoint = "${endpoint}"
      timeout = "10s"
      tls {
        ca_file = "${caFile}"
        cert_file = "${certFile}"
        key_file = "${keyFile}"
      }
    }
    sending_queue {
      enabled = true
      num_consumers = 2
      queue_size = 128
    }
    retry_on_failure {
      enabled = true
      initial_interval = "1s"
      max_interval = "30s"
      max_elapsed_time = "5m"
    }
  }
''
