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
    virtualisation.memorySize = 2048;
    networking.hosts."127.0.0.1" = [ "tempo.test" ];
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
    environment.systemPackages = [ pkgs.curl ];
  };
  testScript = builtins.readFile ./tracing/test.py;
}
