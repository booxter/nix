{ config, lib, ... }:
let
  cfg = config.host.externalService;
  enabledMtlsClients = lib.filterAttrs (
    _: client: client.enable && client.category == "internal"
  ) config.host.pki.clients;
in
{
  assertions = builtins.concatLists (
    lib.mapAttrsToList (
      hostName: vhost:
      lib.optionals vhost.upstreamTls.enable [
        {
          assertion = vhost.upstreamTls.clientName != "";
          message = "host.externalService.virtualHosts.${hostName}.upstreamTls.clientName must be set when upstream mTLS is enabled.";
        }
        {
          assertion = vhost.upstreamTls.serverName != "";
          message = "host.externalService.virtualHosts.${hostName}.upstreamTls.serverName must be set when upstream mTLS is enabled.";
        }
        {
          assertion = builtins.hasAttr vhost.upstreamTls.clientName enabledMtlsClients;
          message = "host.externalService.virtualHosts.${hostName}.upstreamTls.clientName must reference an enabled internal-category host.pki.clients entry.";
        }
      ]
    ) cfg.virtualHosts
  );
}
