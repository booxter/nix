{
  config,
  outputs ? {
    nixosConfigurations = { };
  },
}:
let
  cfg = config.host.adaptiveUploadPolicy;
  transmissionDestination = if cfg == null then null else cfg.destinations.transmission;
  qosDestination = if cfg == null then null else cfg.destinations.qos;
  transmission = if transmissionDestination == null then null else config.host.transmission or null;
  jellyfinHostName = if cfg == null then null else cfg.source.jellyfin.host;
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
    if cfg == null then
      null
    else if cfg.source.jellyfin.exporterUrl != null then
      cfg.source.jellyfin.exporterUrl
    else if jellyfinHost == null || jellyfinEndpoint == null then
      null
    else
      "https://${jellyfinHost.networking.hostName}:${toString jellyfinEndpoint.port}${jellyfinEndpoint.path}";
  pkiClientName = "jellyfin-upload-policy";
  pkiClient = config.host.pki.clients.${pkiClientName} or null;
  pkiMaterialization = if pkiClient == null then null else pkiClient.materializations.default;
  qosProfileName = "adaptive_upload";
  qosLimitName = if qosDestination == null then null else qosDestination.limit;
  qosProfile = config.host.qos.interfaces.${qosProfileName} or null;
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

  intervalSeconds = 5;
  maxStateAgeSeconds = 15;
  stateFile = "/run/adaptive-upload-policy/state.json";
  stateDir = "/run/adaptive-upload-policy";
  metricsDirectory = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "/var/lib/prometheus-node-exporter-textfile/adaptive-upload-policy.prom";
  user = "adaptive-upload-policy";
  group = "adaptive-upload-policy";

  policy = {
    idleRateMbit = 25;
    minimumRateMbit = 1;
    relaxationHoldSeconds = 90;
  };

  jellyfin = {
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
  };

  mtls =
    if jellyfinHostName == null then
      null
    else
      {
        caFile = config.host.pki.authority.rootCaCertificate or null;
        certificateFile = if pkiMaterialization == null then null else pkiMaterialization.certificatePath;
        keyFile = if pkiMaterialization == null then null else pkiMaterialization.keyPath;
        dependencyUnits = [ "sops-install-secrets.service" ];
      };

  transmissionOutput =
    if transmissionDestination == null then
      null
    else
      {
        rpcUrl = if transmission == null then null else transmission.rpcUrl;
        requestTimeoutSeconds = 20;
        inherit (transmissionDestination) headroomPercent;
        local = transmission != null && transmission.enable;
      };

  qosOutput =
    if qosDestination == null then
      null
    else
      {
        profile = qosProfileName;
        limit = qosLimitName;
      };

  qosLimit =
    if qosProfile == null || qosLimitName == null then
      null
    else
      qosProfile.limits.${qosLimitName} or null;
  qosService = "qos-${qosProfileName}.service";
}
