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
    in
    lib.optionals (builtins.pathExists secretPath) (
      map (
        certificate:
        secretSpec host secretPath certificate.category certificate.name certificate.secretPrefix
          certificate.certificateField
      ) configuredHost.host.pki.managedCertificates
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
