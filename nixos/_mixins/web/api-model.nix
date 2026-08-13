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
      url =
        if service == null then
          null
        else
          "https://${service.internal.serverName}:${toString service.health.backend.port}";
      healthUrl =
        if service == null then
          null
        else
          "https://${service.internal.serverName}:${toString service.health.backend.port}${api.healthPath}";
    }
  ) config.host.web.api;
}
