{
  config,
  enabledClients,
  lib,
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
    assertion = enabledClients == { } || config.host.pki.authority != null;
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
