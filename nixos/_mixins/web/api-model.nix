{ config, lib }:
{
  resolved = lib.mapAttrs (
    name: api:
    let
      service = config.host.web.services.${api.service} or null;
    in
    api
    // {
      inherit name service;
      url = if service == null then null else "https://${service.internal.serverName}:9443";
      healthUrl =
        if service == null then null else "https://${service.internal.serverName}:9443${api.healthPath}";
    }
  ) config.host.web.api;
}
