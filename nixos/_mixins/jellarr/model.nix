{ config, outputs }:
let
  targetHost = config.host.jellarr.target.host;
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
  watchstate = if targetConfig == null then null else targetConfig.host.watchstate;
in
{
  inherit exists;
  jellyfinEnabled = jellyfin != null && jellyfin.enable;
  url =
    if jellyfin == null || !jellyfin.enable then
      null
    else if local then
      jellyfin.localUrl
    else
      jellyfin.publicUrl;
  mediaLibraryRoot =
    if jellyfin == null || !jellyfin.enable then null else "${jellyfin.media.mountPoint}/library";
  gpuRenderDevice =
    if jellyfin == null || !jellyfin.enable then null else targetConfig.host.hardware.gpu.renderDevice;
  watchstateWebhookUrl =
    if watchstate == null || !watchstate.enable then null else "${watchstate.localUrl}/v1/api/webhook";
}
