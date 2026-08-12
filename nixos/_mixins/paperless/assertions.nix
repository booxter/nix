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
  textModel = if cfg.gpt.textModel == null then null else gptModels.${cfg.gpt.textModel} or null;
  visionModel =
    if cfg.gpt.visionModel == null then null else gptModels.${cfg.gpt.visionModel} or null;
in
{
  assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.storage.provider != null;
      message = "host.paperless.storage.provider must be set when Paperless is enabled.";
    }
    {
      assertion = config.host.mailer != null;
      message = "Paperless requires mailer policy for realm '${config.host.realm}'.";
    }
    {
      assertion = ssoApplication != null;
      message = "host.paperless.sso.application must name a declared SSO application.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.adminGroup != null;
      message = "The Paperless SSO application must declare an administrator group.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.userGroup != null;
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
      assertion = !cfg.gpt.enable || gptProvider != null;
      message = "host.paperless.gpt.ollama.providerHost must name a known NixOS host.";
    }
    {
      assertion = !cfg.gpt.enable || (gptProvider != null && gptProvider.host.realm == config.host.realm);
      message = "Paperless GPT and its Ollama provider must be in the same realm.";
    }
    {
      assertion = !cfg.gpt.enable || (gptProvider != null && gptProvider.host.ollama.enable);
      message = "The selected Paperless GPT provider must enable Ollama.";
    }
    {
      assertion = !cfg.gpt.enable || textModel != null;
      message = "host.paperless.gpt.textModel must select a model advertised by the Ollama provider.";
    }
    {
      assertion = !cfg.gpt.enable || visionModel != null;
      message = "host.paperless.gpt.visionModel must select a model advertised by the Ollama provider.";
    }
    {
      assertion =
        !cfg.gpt.enable || (visionModel != null && builtins.elem "vision" visionModel.capabilities);
      message = "host.paperless.gpt.visionModel must advertise the vision capability.";
    }
  ];
}
