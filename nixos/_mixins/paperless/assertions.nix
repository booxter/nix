{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model)
    cfg
    gptModels
    gptProvider
    ssoApplication
    users
    ;
  textModel = if cfg == null || cfg.gpt == null then null else gptModels.${cfg.gpt.textModel} or null;
  visionModel =
    if cfg == null || cfg.gpt == null then null else gptModels.${cfg.gpt.visionModel} or null;
in
{
  assertions = lib.optionals (cfg != null) [
    {
      assertion = config.host.mailer != null;
      message = "Paperless requires mailer policy for realm '${config.host.realm}'.";
    }
    {
      assertion = ssoApplication != null;
      message = "Paperless requires the realm's 'paperless' SSO application.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.roles ? admin;
      message = "The Paperless SSO application must declare an administrator group.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.roles ? user;
      message = "The Paperless SSO application must declare a user group.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.bootstrapOwner != null;
      message = "The Paperless SSO application must declare a bootstrap owner.";
    }
    {
      assertion = users != { };
      message = "The Paperless SSO application has no authorized users.";
    }
    {
      assertion = cfg.gpt == null || gptProvider != null;
      message = "host.paperless.gpt.providerHost must name a known NixOS host.";
    }
    {
      assertion = cfg.gpt == null || (gptProvider != null && gptProvider.host.realm == config.host.realm);
      message = "Paperless GPT and its Ollama provider must be in the same realm.";
    }
    {
      assertion = cfg.gpt == null || (gptProvider != null && gptProvider.host.ollama != null);
      message = "The selected Paperless GPT provider must enable Ollama.";
    }
    {
      assertion = cfg.gpt == null || textModel != null;
      message = "host.paperless.gpt.textModel must select a model advertised by the Ollama provider.";
    }
    {
      assertion = cfg.gpt == null || visionModel != null;
      message = "host.paperless.gpt.visionModel must select a model advertised by the Ollama provider.";
    }
    {
      assertion =
        cfg.gpt == null || (visionModel != null && builtins.elem "vision" visionModel.capabilities);
      message = "host.paperless.gpt.visionModel must advertise the vision capability.";
    }
  ];
}
