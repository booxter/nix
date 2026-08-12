{
  config,
  enabledClients,
  lib,
  model,
}:
let
  managedCertificates = config.host.pki.managedCertificates;
  managedCertificateKeys = map (
    certificate: "${certificate.category}/${certificate.name}"
  ) managedCertificates;
  managedCertificateSourceKeys = map (
    certificate: "${certificate.secretPrefix}/${certificate.certificateField}"
  ) managedCertificates;
in
[
  {
    assertion = builtins.length model.authorityNames <= 1;
    message = "realm '${config.host.realm}' has multiple internal PKI authorities: ${lib.concatStringsSep ", " model.authorityNames}";
  }
  {
    assertion =
      config.host.pki.role != "authority" || config.host.pki.authority.rootCaCertificate != null;
    message = "internal PKI authority '${config.networking.hostName}' must declare its root CA certificate";
  }
  {
    assertion = enabledClients == { } || model.realmAuthority != null;
    message =
      "realm '${config.host.realm}' has no internal PKI authority, but host '${config.networking.hostName}' enables clients: "
      + lib.concatStringsSep ", " (builtins.attrNames enabledClients);
  }
  {
    assertion =
      builtins.length managedCertificateKeys == builtins.length (lib.unique managedCertificateKeys);
    message = "host.pki.managedCertificates must not duplicate a category/name pair";
  }
  {
    assertion =
      builtins.length managedCertificateSourceKeys
      == builtins.length (lib.unique managedCertificateSourceKeys);
    message = "host.pki.managedCertificates must not duplicate a SOPS certificate field";
  }
]
