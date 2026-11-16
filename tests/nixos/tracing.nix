{ pkgs, ... }:
let
  pki = import ./lib/tls-pki.nix {
    inherit pkgs;
    serverName = "tempo.test";
    clientName = "alloy-test";
  };
in
pkgs.testers.runNixOSTest {
  name = "tracing";
  nodes.machine = {
    imports = [ ../../nixos/_mixins/observability/tempo/socket.nix ];
    host.observability.tracing.enable = true;
    virtualisation.memorySize = 2048;
    networking.hosts."127.0.0.1" = [ "tempo.test" ];
    # Reserve Loki's gRPC port before Tempo starts, as on the monitoring host.
    systemd.sockets.loki-grpc.listenStreams = [ "127.0.0.1:9095" ];
    systemd.services.loki-grpc.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    systemd.services.tempo = {
      requires = [ "loki-grpc.socket" ];
      after = [ "loki-grpc.socket" ];
    };
    services.tempo = {
      enable = true;
      settings = import ../../nixos/_mixins/observability/tempo/settings.nix;
    };
    services.alloy.enable = true;
    environment.etc."alloy/traces.alloy".text =
      import ../../nixos/_mixins/observability/tempo/pipeline.nix
        {
          endpoint = "https://tempo.test";
          caFile = "${pki}/ca.crt";
          certFile = "${pki}/client.crt";
          keyFile = "${pki}/client.key";
        };
    services.nginx = {
      enable = true;
      virtualHosts."tempo.test" = {
        forceSSL = true;
        sslCertificate = "${pki}/server.crt";
        sslCertificateKey = "${pki}/server.key";
        extraConfig = ''
          ssl_client_certificate ${pki}/ca.crt;
          ssl_verify_client on;
        '';
        locations."/".proxyPass = "http://127.0.0.1:4319";
      };
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
    environment.etc."trace-helper".source = import ../../nixos/_mixins/media-repair/helper.nix {
      inherit pkgs;
      inherit (pkgs) lib;
      roots."root:test" = "/var/lib/tracing-test";
    };
    users.groups.media = { };
    users.users.media-repair-worker = {
      isSystemUser = true;
      group = "media";
      extraGroups = [ "telemetry" ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/tracing-test 0755 root root -" ];
  };
  testScript = builtins.readFile ./tracing/test.py;
}
