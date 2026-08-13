{
  config,
  lib,
  outputs,
}:
let
  cfg = config.host.seerr;
  localHost = config.networking.hostName;
  resolveHost =
    hostName:
    if hostName == null then
      null
    else if hostName == localHost then
      config
    else if builtins.hasAttr hostName outputs.nixosConfigurations then
      outputs.nixosConfigurations.${hostName}.config
    else
      null;
  jellyfinHost = resolveHost cfg.integrations.jellyfin.host;
  mediaModel = import ../media-libraries/model.nix { inherit config lib; };
  apiModel = import ../web/api-model.nix { inherit config lib; };
  resolveServarr = kind: name: integration: {
    inherit kind name integration;
    api = apiModel.resolved.${integration.api} or null;
    media = mediaModel.resolved.${integration.library} or null;
  };
in
{
  inherit cfg jellyfinHost;
  jellyfin = if jellyfinHost == null then null else jellyfinHost.host.jellyfin;
  radarr = lib.mapAttrs (resolveServarr "radarr") cfg.integrations.radarr;
  sonarr = lib.mapAttrs (resolveServarr "sonarr") cfg.integrations.sonarr;
  service = config.host.web.services.seerr;
}
