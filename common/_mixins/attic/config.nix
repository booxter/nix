{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.attic.client;
  realmAttic = facts.realms.${config.host.realm}.services.attic or null;
in
{
  config = lib.mkIf cfg.enable {
    sops = {
      secrets."attic/token" = { };
      templates."attic-client-config.toml" = {
        owner = "root";
        group = "root";
        mode = "0400";
        content = ''
          default-server = "realm"
          [servers.realm]
          endpoint = "${realmAttic.endpoint}"
          token = "${config.sops.placeholder."attic/token"}"
        '';
      };
    };
  };
}
