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
  configurations =
    map (configuration: configuration.config) (
      builtins.attrValues (removeAttrs outputs.nixosConfigurations [ localHost ])
    )
    ++ [ config ];
  watchstates = builtins.filter (
    hostConfig:
    hostConfig.host.watchstate.enable && hostConfig.host.watchstate.jellyfin.host == targetHost
  ) configurations;
  watchstatePlugins = builtins.concatLists (
    map (hostConfig: hostConfig.host.watchstate.jellyfin.declarativeConfig.plugins or [ ]) watchstates
  );
  jellyfinConfig = if jellyfin == null then { } else jellyfin.declarativeConfig;
in
{
  inherit exists watchstates;
  jellyfinEnabled = jellyfin != null && jellyfin.enable;
  url =
    if jellyfin == null || !jellyfin.enable then
      null
    else if local then
      jellyfin.localUrl
    else
      jellyfin.publicUrl;
  declarativeConfig = jellyfinConfig // {
    plugins = (jellyfinConfig.plugins or [ ]) ++ watchstatePlugins;
  };
}
