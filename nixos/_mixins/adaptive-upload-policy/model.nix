{ config }:
let
  cfg = config.services.adaptive-upload-policy;
  qosProfile = config.host.qos.interfaces.${cfg.outputs.qos.profile} or null;
in
{
  inherit cfg qosProfile;
  maxStateAgeSeconds =
    if cfg.maxStateAgeSeconds != null then cfg.maxStateAgeSeconds else cfg.intervalSeconds * 3;
  metricsFile = "${cfg.metrics.directory}/${cfg.metrics.fileName}";
  mtls = cfg.source.jellyfin.mtls;
  qosLimit = if qosProfile != null then qosProfile.limits.${cfg.outputs.qos.limit} or null else null;
  qosService = "qos-${cfg.outputs.qos.profile}.service";
  stateDir = dirOf cfg.stateFile;
  transmissionRpcUrl =
    if cfg.outputs.transmission.rpcUrl != null then
      cfg.outputs.transmission.rpcUrl
    else
      "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}/transmission/rpc";
}
