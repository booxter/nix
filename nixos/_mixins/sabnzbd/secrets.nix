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
  config = lib.mkIf cfg.enable {
    sops.secrets = lib.genAttrs (
      [
        cfg.secrets.apiKey
        cfg.secrets.nzbKey
      ]
      ++ serverSecretNames
    ) (_: { });

    sops.templates."sabnzbd-secret.ini" = {
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      content = ''
        [misc]
        api_key = ${builtins.getAttr cfg.secrets.apiKey config.sops.placeholder}
        nzb_key = ${builtins.getAttr cfg.secrets.nzbKey config.sops.placeholder}

        [servers]
        ${serverSecretIni}
      '';
    };
  };
}
