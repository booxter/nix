{
  config,
  outputs ? {
    nixosConfigurations = { };
  },
}:
let
  hostCfg = config.host.adaptiveUploadPolicy;
  transmissionDestination = if hostCfg == null then null else hostCfg.destinations.transmission;
  qosDestination = if hostCfg == null then null else hostCfg.destinations.qos;
  transmission = if transmissionDestination == null then null else config.host.transmission or null;
  jellyfinHostName = if hostCfg == null then null else hostCfg.source.jellyfin.host;
  jellyfinHost =
    if jellyfinHostName == null then
      null
    else
      outputs.nixosConfigurations.${jellyfinHostName}.config or null;
  jellyfinEndpoint =
    if jellyfinHost == null then
      null
    else
      jellyfinHost.host.observability.prometheusEndpoints.jellyfin or null;
  exporterUrl =
    if hostCfg == null then
      null
    else if hostCfg.source.jellyfin.exporterUrl != null then
      hostCfg.source.jellyfin.exporterUrl
    else if jellyfinHost == null || jellyfinEndpoint == null then
      null
    else
      "https://${jellyfinHost.networking.hostName}:${toString jellyfinEndpoint.port}${jellyfinEndpoint.path}";
  pkiClientName = "jellyfin-upload-policy";
  pkiClient = config.host.pki.clients.${pkiClientName} or null;
  pkiMaterialization = if pkiClient == null then null else pkiClient.materializations.default;
  mtlsEnabled = jellyfinHostName != null;
  qosProfileName = "adaptive_upload";
  qosLimitName = if qosDestination == null then null else qosDestination.limit;
  qosProfile = config.host.qos.interfaces.${qosProfileName} or null;
  cfg =
    if hostCfg == null then
      null
    else
      hostCfg
      // {
        intervalSeconds = 5;
        maxStateAgeSeconds = null;
        policy = {
          idleRateMbit = 25;
          minimumRateMbit = 1;
          relaxationHoldSeconds = 90;
        };
        source.jellyfin = hostCfg.source.jellyfin // {
          inherit exporterUrl;
          requestTimeoutSeconds = 10;
          mediaTypes = [
            "audio"
            "audiobook"
            "episode"
            "movie"
            "musicvideo"
            "trailer"
            "video"
          ];
          mtls = {
            enable = mtlsEnabled;
            caFile = config.host.pki.authority.rootCaCertificate or null;
            certificateFile =
              if !mtlsEnabled || pkiMaterialization == null then null else pkiMaterialization.certificatePath;
            keyFile = if !mtlsEnabled || pkiMaterialization == null then null else pkiMaterialization.keyPath;
            dependencyUnits = [ "sops-install-secrets.service" ];
          };
        };
        outputs = {
          transmission = {
            enable = transmissionDestination != null;
            rpcUrl = if transmission == null then null else transmission.rpcUrl;
            requestTimeoutSeconds = 20;
            headroomPercent =
              if transmissionDestination == null then 95 else transmissionDestination.headroomPercent;
            local = transmissionDestination != null && transmission != null && transmission.enable;
          };
          qos = {
            enable = qosDestination != null;
            profile = qosProfileName;
            limit = qosLimitName;
          };
        };
        metrics = {
          enable = true;
          directory = "/var/lib/prometheus-node-exporter-textfile";
          fileName = "adaptive-upload-policy.prom";
        };
      };
in
{
  inherit
    cfg
    exporterUrl
    jellyfinEndpoint
    jellyfinHost
    pkiClientName
    qosDestination
    qosLimitName
    qosProfile
    qosProfileName
    transmission
    transmissionDestination
    ;
  maxStateAgeSeconds = cfg.intervalSeconds * 3;
  metricsFile = "${cfg.metrics.directory}/${cfg.metrics.fileName}";
  mtls = cfg.source.jellyfin.mtls;
  qosLimit =
    if qosProfile == null || qosLimitName == null then
      null
    else
      qosProfile.limits.${qosLimitName} or null;
  qosService = "qos-${qosProfileName}.service";
  stateDir = dirOf cfg.stateFile;
  transmissionRpcUrl = cfg.outputs.transmission.rpcUrl;
}
