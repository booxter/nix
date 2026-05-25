rec {
  internalPkiRootCaPath = import ./home-internal-pki-root-ca.nix;
  nodeExporterSecretPrefix = "prometheus/node_exporter";

  mkNodeExporterWebConfig =
    {
      certFile,
      keyFile,
    }:
    ''
      tls_server_config:
        cert_file: ${certFile}
        key_file: ${keyFile}
        client_auth_type: RequireAndVerifyClientCert
        client_ca_file: ${internalPkiRootCaPath}
    '';
}
