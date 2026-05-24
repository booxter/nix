rec {
  internalPkiRootCaPath = ../common/_mixins/internal-pki/home-internal-pki-root-ca.crt;
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
