{
  config,
  lib,
  ...
}:
let
  cfg = config.host.attic.client;
  servers = config.host.attic.realmServers;
  serverNames = builtins.attrNames servers;
  serverConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: server: ''
      [servers."${name}"]
      endpoint = "${server.endpoint}"
      token = "${config.sops.placeholder."attic/token"}"
    '') servers
  );
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
          default-server = "${builtins.head serverNames}"
          ${serverConfig}
        '';
      };
    };
  };
}
