{
  config,
  lib,
  outputs ? {
    nixosConfigurations = { };
  },
  ...
}:
let
  model = import ./model.nix { inherit config outputs; };
  inherit (model)
    cfg
    downloadClient
    downloadClientDestinationNames
    exporterUrl
    jellyfinEndpoint
    jellyfinHost
    mtls
    qosDestination
    qosDestinationNames
    qosLimit
    qosProfile
    ;
in
{
  config.assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.source.jellyfin.host != null || cfg.source.jellyfin.exporterUrl != null;
      message = "host.adaptiveUploadPolicy requires a Jellyfin source host";
    }
    {
      assertion = cfg.source.jellyfin.host == null || jellyfinHost != null;
      message = "host.adaptiveUploadPolicy.source.jellyfin.host must select a NixOS host";
    }
    {
      assertion = cfg.source.jellyfin.host == null || jellyfinEndpoint != null;
      message = "host.adaptiveUploadPolicy Jellyfin source must export playback metrics";
    }
    {
      assertion = exporterUrl != null;
      message = "host.adaptiveUploadPolicy could not resolve the Jellyfin exporter URL";
    }
    {
      assertion = builtins.length downloadClientDestinationNames <= 1;
      message = "host.adaptiveUploadPolicy supports at most one download-client destination";
    }
    {
      assertion = builtins.length qosDestinationNames <= 1;
      message = "host.adaptiveUploadPolicy supports at most one QoS destination";
    }
    {
      assertion = cfg.destinations.downloadClients != { } || cfg.destinations.qos != { };
      message = "host.adaptiveUploadPolicy requires at least one destination";
    }
    {
      assertion = cfg.destinations.downloadClients == { } || downloadClient != null;
      message = "host.adaptiveUploadPolicy download-client destination must select a registered client";
    }
    {
      assertion = downloadClient == null || downloadClient.kind == "torrent";
      message = "host.adaptiveUploadPolicy download-client destination must select a torrent client";
    }
    {
      assertion = downloadClient == null || downloadClient.implementation == "transmission";
      message = "host.adaptiveUploadPolicy currently supports only Transmission download clients";
    }
    {
      assertion = downloadClient == null || downloadClient.authentication.type == "none";
      message = "host.adaptiveUploadPolicy does not support authenticated download clients";
    }
    {
      assertion = !cfg.outputs.transmission.enable || cfg.outputs.transmission.rpcUrl != null;
      message = "host.adaptiveUploadPolicy Transmission destination requires an RPC URL";
    }
    {
      assertion = !mtls.enable || mtls.certificateFile != null;
      message = "host.adaptiveUploadPolicy could not materialize its mTLS certificate";
    }
    {
      assertion = !mtls.enable || mtls.keyFile != null;
      message = "host.adaptiveUploadPolicy could not materialize its mTLS private key";
    }
    {
      assertion = !cfg.outputs.qos.enable || qosProfile != null;
      message = "host.adaptiveUploadPolicy could not configure its QoS profile";
    }
    {
      assertion = !cfg.outputs.qos.enable || qosLimit != null;
      message = "host.adaptiveUploadPolicy could not configure its uplink QoS limit";
    }
    {
      assertion = qosLimit == null || qosLimit.direction == "egress";
      message = "host.adaptiveUploadPolicy can update only egress host.qos limits";
    }
    {
      assertion = qosProfile == null || cfg.fallbackRateMbit <= qosProfile.linkRateMbit;
      message = "host.adaptiveUploadPolicy fallback rate must not exceed the QoS profile link rate";
    }
    {
      assertion =
        qosDestination == null
        || qosDestination.accountingName == null
        || qosDestination.match.protocol == "udp";
      message = "host.adaptiveUploadPolicy QoS accounting requires UDP traffic";
    }
  ];
}
