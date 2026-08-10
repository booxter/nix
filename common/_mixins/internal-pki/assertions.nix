{
  config,
  enabledClients,
  lib,
  model,
}:
[
  {
    assertion = builtins.length model.authorityNames <= 1;
    message = "realm '${config.host.realm}' has multiple internal PKI authorities: ${lib.concatStringsSep ", " model.authorityNames}";
  }
  {
    assertion =
      !config.host.internalPki.authority.enable
      || config.host.internalPki.authority.rootCaCertificate != null;
    message = "internal PKI authority '${config.networking.hostName}' must declare its root CA certificate";
  }
  {
    assertion = enabledClients == { } || model.realmAuthority != null;
    message =
      "realm '${config.host.realm}' has no internal PKI authority, but host '${config.networking.hostName}' enables clients: "
      + lib.concatStringsSep ", " (builtins.attrNames enabledClients);
  }
  {
    assertion = !config.host.internalPki.enable || model.realmAuthority != null;
    message = "realm '${config.host.realm}' has no internal PKI authority";
  }
]
