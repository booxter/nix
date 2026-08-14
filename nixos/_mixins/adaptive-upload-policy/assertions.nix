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
    exporterUrl
    jellyfinEndpoint
    jellyfinHost
    mtls
    qosDestination
    qosLimit
    qosProfile
    transmission
    transmissionDestination
    transmissionOutput
    ;
in
{
  config.assertions = lib.optionals (cfg != null) [
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
      assertion = transmissionDestination != null || qosDestination != null;
      message = "host.adaptiveUploadPolicy requires at least one destination";
    }
    {
      assertion = transmissionDestination == null || (transmission != null && transmission.enable);
      message = "host.adaptiveUploadPolicy Transmission destination requires local Transmission";
    }
    {
      assertion = transmissionOutput == null || transmissionOutput.rpcUrl != null;
      message = "host.adaptiveUploadPolicy Transmission destination requires an RPC URL";
    }
    {
      assertion = mtls == null || mtls.certificateFile != null;
      message = "host.adaptiveUploadPolicy could not materialize its mTLS certificate";
    }
    {
      assertion = mtls == null || mtls.keyFile != null;
      message = "host.adaptiveUploadPolicy could not materialize its mTLS private key";
    }
    {
      assertion = qosDestination == null || qosProfile != null;
      message = "host.adaptiveUploadPolicy could not configure its QoS profile";
    }
    {
      assertion = qosDestination == null || qosLimit != null;
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
