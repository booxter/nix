{
  config,
  enabledClients,
  lib,
}:
let
  certificates = builtins.attrValues config.host.pki.certificates;
  managedCertificateSourceKeys = map (
    certificate:
    "${certificate.secretPrefix}/"
    + (
      if lib.hasSuffix "_client" certificate.category then
        "client_crt_unencrypted"
      else
        "server_crt_unencrypted"
    )
  ) certificates;
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
      builtins.length managedCertificateSourceKeys
      == builtins.length (lib.unique managedCertificateSourceKeys);
    message = "host.pki.certificates must not duplicate a SOPS certificate field";
  }
]
