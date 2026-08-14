{ config, lib, ... }:
let
  cfg = config.host.sabnzbd;
  credentialName = server: field: "${server.credentialsSecretPrefix}/${field}";
  serverSecretNames = lib.concatMap (
    server:
    map (credentialName server) [
      "username"
      "password"
    ]
  ) (builtins.attrValues cfg.servers);
  serverSecretIni = lib.concatMapStringsSep "\n\n" (
    name:
    let
      server = cfg.servers.${name};
    in
    ''
      [[${name}]]
      username = ${builtins.getAttr (credentialName server "username") config.sops.placeholder}
      password = ${builtins.getAttr (credentialName server "password") config.sops.placeholder}
    ''
  ) (builtins.attrNames cfg.servers);
in
{
  config = lib.mkIf (cfg != null) {
    sops.secrets = lib.genAttrs (
      [
        "sabnzbd/apiKey"
        "sabnzbd/nzbKey"
      ]
      ++ serverSecretNames
    ) (_: { });

    sops.templates."sabnzbd-secret.ini" = {
      owner = "sabnzbd";
      group = "media";
      mode = "0400";
      content = ''
        [misc]
        api_key = ${config.sops.placeholder."sabnzbd/apiKey"}
        nzb_key = ${config.sops.placeholder."sabnzbd/nzbKey"}

        [servers]
        ${serverSecretIni}
      '';
    };
  };
}
