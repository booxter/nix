{
  config,
  outputs ? {
    nixosConfigurations = { };
  },
}:
let
  hostCfg = config.host.adaptiveUploadPolicy;
  downloadClientDestinationNames = builtins.attrNames hostCfg.destinations.downloadClients;
  qosDestinationNames = builtins.attrNames hostCfg.destinations.qos;
  downloadClientDestinationName =
    if builtins.length downloadClientDestinationNames == 1 then
      builtins.head downloadClientDestinationNames
    else
      null;
  qosDestinationName =
    if builtins.length qosDestinationNames == 1 then builtins.head qosDestinationNames else null;
  downloadClientDestination =
    if downloadClientDestinationName == null then
      null
    else
      hostCfg.destinations.downloadClients.${downloadClientDestinationName};
  qosDestination =
    if qosDestinationName == null then null else hostCfg.destinations.qos.${qosDestinationName};
  downloadClient =
    if downloadClientDestination == null then
      null
    else
      config.host.downloads.clients.${downloadClientDestination.client} or null;
  jellyfinHostName = hostCfg.source.jellyfin.host;
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
    if hostCfg.source.jellyfin.exporterUrl != null then
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
  qosLimitName = if qosDestinationName == null then null else qosDestinationName;
  qosProfile = config.host.qos.interfaces.${qosProfileName} or null;
  cfg = hostCfg // {
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
          if !mtlsEnabled || pkiMaterialization == null then
            null
          else
            config.sops.secrets.${pkiMaterialization.certificateSecretName}.path;
        keyFile =
          if !mtlsEnabled || pkiMaterialization == null then
            null
          else
            config.sops.secrets.${pkiMaterialization.keySecretName}.path;
        dependencyUnits = [ "sops-install-secrets.service" ];
      };
    };
    outputs = {
      transmission = {
        enable = downloadClientDestination != null;
        rpcUrl = if downloadClient == null then null else downloadClient.endpoint;
        requestTimeoutSeconds = 20;
        headroomPercent =
          if downloadClientDestination == null then 95 else downloadClientDestination.headroomPercent;
        local =
          downloadClientDestination != null
          && config.host.transmission.enable
          && downloadClientDestination.client == "transmission";
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
    downloadClient
    downloadClientDestination
    downloadClientDestinationName
    downloadClientDestinationNames
    exporterUrl
    jellyfinEndpoint
    jellyfinHost
    pkiClientName
    qosDestination
    qosDestinationName
    qosDestinationNames
    qosLimitName
    qosProfile
    qosProfileName
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
