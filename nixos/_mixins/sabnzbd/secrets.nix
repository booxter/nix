{ config, lib, ... }:
let
  cfg = config.host.sabnzbd;
  credentialName = name: field: "sabnzbd/servers/${name}/${field}";
  serverSecretNames = lib.concatMap (
    name:
    map (credentialName name) [
      "username"
      "password"
    ]
  ) (builtins.attrNames cfg.servers);
  serverSecretIni = lib.concatMapStringsSep "\n\n" (name: ''
    [[${name}]]
    username = ${builtins.getAttr (credentialName name "username") config.sops.placeholder}
    password = ${builtins.getAttr (credentialName name "password") config.sops.placeholder}
  '') (builtins.attrNames cfg.servers);
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
