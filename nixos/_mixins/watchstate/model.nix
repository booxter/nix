{ config, outputs }:
let
  targetHost = config.host.watchstate.jellyfin.host;
  localHost = config.networking.hostName;
  local = targetHost == localHost;
  exists = local || builtins.hasAttr targetHost outputs.nixosConfigurations;
  targetConfig =
    if local then
      config
    else if exists then
      outputs.nixosConfigurations.${targetHost}.config
    else
      null;
  jellyfin = if targetConfig == null then null else targetConfig.host.jellyfin;
in
{
  inherit
    exists
    jellyfin
    local
    targetHost
    ;
  jellyfinEnabled = jellyfin != null;
  libraryPath = if jellyfin == null then null else "${jellyfin.media.mountPoint}/library";
  webhookUrl =
    if local then
      "${config.host.watchstate.localUrl}/v1/api/webhook"
    else
      "${config.host.web.services.watchstate.internal.url}/v1/api/webhook";
}
