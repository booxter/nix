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
in
{
  inherit exists;
  jellyfinEnabled = jellyfin != null;
  url =
    if jellyfin == null then
      null
    else if local then
      jellyfin.localUrl
    else
      jellyfin.publicUrl;
  declarativeConfig =
    if targetConfig == null then { } else targetConfig.host.jellyfinDeclarativeConfig;
}
