{ config, lib, ... }:
let
  model = import ./model.nix { inherit config; };
  inherit (model)
    cfg
    mtls
    qosLimit
    qosProfile
    ;
in
{
  config.assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.policy.minimumRateMbit <= cfg.policy.idleRateMbit;
      message = "services.adaptive-upload-policy.policy.minimumRateMbit must not exceed idleRateMbit";
    }
    {
      assertion = cfg.outputs.transmission.enable || cfg.outputs.qos.enable;
      message = "services.adaptive-upload-policy requires at least one enabled output";
    }
    {
      assertion = !mtls.enable || mtls.certificateFile != null;
      message = "services.adaptive-upload-policy requires an mTLS certificate file";
    }
    {
      assertion = !mtls.enable || mtls.keyFile != null;
      message = "services.adaptive-upload-policy requires an mTLS private key file";
    }
    {
      assertion = !cfg.outputs.qos.enable || qosProfile != null;
      message = "services.adaptive-upload-policy.outputs.qos.profile must reference a host.qos profile";
    }
    {
      assertion = !cfg.outputs.qos.enable || qosLimit != null;
      message = "services.adaptive-upload-policy.outputs.qos.limit must reference a host.qos limit";
    }
    {
      assertion = !cfg.outputs.qos.enable || qosLimit == null || qosLimit.direction == "egress";
      message = "services.adaptive-upload-policy can update only egress host.qos limits";
    }
    {
      assertion =
        !cfg.outputs.qos.enable || qosProfile == null || cfg.fallbackRateMbit <= qosProfile.linkRateMbit;
      message = "services.adaptive-upload-policy fallback rate must not exceed the QoS profile link rate";
    }
  ];
}
