{
  facts,
  lib,
  outputs,
  rootCaCertificate,
}:
let
  authorityHost = facts.hosts.hostSpecsByName.pki.name;
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;

  secretSpec = host: secretPath: category: name: prefix: certificateField: {
    inherit category host name;
    source_kind = "repo_secret";
    file_path = null;
    secret = {
      inherit host prefix;
      path = secretPath;
      certificate_field = certificateField;
    };
  };

  hostSpecs =
    host: hostFacts:
    let
      configuredHost = configurations.${host}.config;
      secretPath = ../../secrets + "/${hostFacts.realm}/${host}.yaml";
      internalServices = configuredHost.host.internalHttps.services or { };
      clients = configuredHost.host.internalPki.clients or { };
      proxmoxApi = configuredHost.host.proxmox.apiCertificate or { enable = false; };
      proxmoxPrefix = if proxmoxApi.enable or false then proxmoxApi.secretPrefix else null;
      observabilityEndpoints = configuredHost.host.observability.prometheusEndpoints or { };
      nodeExporterEnabled = configuredHost.host.observability.nodeExporter.mtls.enable or false;

      internalServiceSpecs =
        lib.mapAttrsToList
          (
            name: service:
            secretSpec host secretPath "internal_https_server" name service.secretPrefix
              "server_crt_unencrypted"
          )
          (
            lib.filterAttrs (
              name: service: service.enable && !(name == "proxmox" && service.secretPrefix == proxmoxPrefix)
            ) internalServices
          );
      proxmoxSpecs = lib.optional (proxmoxApi.enable or false) (
        secretSpec host secretPath "internal_https_server" "proxmox-api" proxmoxApi.secretPrefix
          "server_crt_unencrypted"
      );
      clientSpecs = lib.mapAttrsToList (
        name: client:
        secretSpec host secretPath (
          if client.category == "observability" then "observability_client" else "internal_https_client"
        ) name client.secretPrefix "client_crt_unencrypted"
      ) (lib.filterAttrs (_: client: client.enable) clients);
      endpointSpecs =
        lib.mapAttrsToList
          (
            name: endpoint:
            secretSpec host secretPath "observability_endpoint_server" name endpoint.secretPrefix
              "server_crt_unencrypted"
          )
          (
            lib.filterAttrs (
              name: endpoint: endpoint.enable && !(nodeExporterEnabled && name == "node_exporter")
            ) observabilityEndpoints
          );
      nodeExporterSpecs = lib.optional nodeExporterEnabled (
        secretSpec host secretPath "observability_endpoint_server" "node_exporter"
          configuredHost.host.observability.nodeExporter.mtls.secretPrefix
          "server_crt_unencrypted"
      );
    in
    lib.optionals (builtins.pathExists secretPath) (
      internalServiceSpecs ++ proxmoxSpecs ++ clientSpecs ++ endpointSpecs ++ nodeExporterSpecs
    );

  leafCertificates = lib.concatLists (lib.mapAttrsToList hostSpecs facts.hosts.hostSpecsByName);
in
builtins.toFile "pki-certificate-inventory.json" (
  builtins.toJSON {
    authority_host = authorityHost;
    certificates = [
      {
        host = authorityHost;
        category = "ca";
        name = "root";
        source_kind = "repo_file";
        file_path = rootCaCertificate;
        secret = null;
      }
    ]
    ++ leafCertificates;
  }
)
