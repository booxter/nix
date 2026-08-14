{
  config,
  lib,
  outputs,
}:
let
  authority = config.host.pki.authority;
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  realmConfigurations = lib.filterAttrs (
    _: configuration: configuration.config.host.realm == config.host.realm
  ) configurations;
  secretSpec = host: realm: secretPath: category: name: prefix: certificateField: {
    inherit
      category
      host
      name
      realm
      ;
    source_kind = "repo_secret";
    file_path = null;
    secret = {
      inherit host prefix;
      path = secretPath;
      certificate_field = certificateField;
    };
  };
  hostCertificates =
    host: configuration:
    let
      hostConfig = configuration.config;
      realm = hostConfig.host.realm;
      secretPath = ../../secrets + "/${realm}/${host}.yaml";
    in
    lib.optionals (builtins.pathExists secretPath) (
      map (
        certificate:
        secretSpec host realm secretPath certificate.category certificate.name certificate.secretPrefix
          certificate.certificateField
      ) hostConfig.host.pki.managedCertificates
    );
  leafCertificates = lib.concatLists (lib.mapAttrsToList hostCertificates realmConfigurations);
in
assert authority != null;
builtins.toFile "pki-certificate-inventory-${config.host.realm}.json" (
  builtins.toJSON {
    authority_host = authority.hostName;
    realm = config.host.realm;
    certificates = [
      {
        host = authority.hostName;
        realm = config.host.realm;
        category = "ca";
        name = "root";
        source_kind = "repo_file";
        file_path = authority.rootCaCertificate;
        secret = null;
      }
    ]
    ++ leafCertificates;
  }
)
