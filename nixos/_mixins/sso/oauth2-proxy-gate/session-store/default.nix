{
  config,
  lib,
  ...
}:
let
  helpers = import ../../oauth2-proxy-gate-lib.nix { };
  enabledGates = lib.filterAttrs (
    _: gate: gate.enable && gate.sessionRefresh != null
  ) config.host.sso.oauth2ProxyGates;
in
{
  imports = [ ./assertions.nix ];

  config = lib.mkIf (enabledGates != { }) {
    services.redis.servers = lib.mapAttrs' (
      gateName: gate:
      lib.nameValuePair (helpers.redisServerName gateName) {
        enable = true;
        bind = "127.0.0.1";
        port = gate.sessionRefresh.redisPort;
        openFirewall = false;
        save = [ ];
        appendOnly = true;
        appendFsync = "everysec";
        settings = {
          maxmemory = "64mb";
          maxmemory-policy = "volatile-ttl";
        };
      }
    ) enabledGates;
  };
}
