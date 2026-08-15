{
  config,
  lib,
}:
let
  categories = import ./categories.nix;
  certificates = builtins.attrValues config.host.pki.certificates;
  managedCertificateSourceKeys = map (
    certificate: "${certificate.secretPrefix}/${categories.${certificate.category}.certificateField}"
  ) certificates;
in
[
  {
    assertion = config.host.pki.clients == { } || config.host.pki.authority != null;
    message =
      "realm '${config.host.realm}' has no internal PKI authority, but host '${config.networking.hostName}' enables clients: "
      + lib.concatStringsSep ", " (builtins.attrNames config.host.pki.clients);
  }
  {
    assertion =
      builtins.length managedCertificateSourceKeys
      == builtins.length (lib.unique managedCertificateSourceKeys);
    message = "host.pki.certificates must not duplicate a SOPS certificate field";
  }
]
