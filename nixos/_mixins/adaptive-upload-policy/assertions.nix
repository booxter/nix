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
    jellyfinEndpoint
    jellyfinHost
    mtls
    qosDestination
    qosProfile
    transmission
    transmissionDestination
    ;
in
{
  config.assertions = lib.optionals (cfg != null) [
    {
      assertion = cfg.source.jellyfin.host != null || cfg.source.jellyfin.exporterUrl != null;
      message = "host.adaptiveUploadPolicy requires a Jellyfin metrics source";
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
      assertion = transmissionDestination != null || qosDestination != null;
      message = "host.adaptiveUploadPolicy requires at least one destination";
    }
    {
      assertion = transmissionDestination == null || transmission != null;
      message = "host.adaptiveUploadPolicy Transmission destination requires local Transmission";
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
      assertion = qosDestination == null || cfg.fallbackRateMbit <= qosProfile.linkRateMbit;
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
