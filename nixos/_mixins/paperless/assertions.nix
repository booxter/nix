{
  config,
  lib,
  paperlessModel,
  ...
}:
let
  inherit (paperlessModel)
    cfg
    aiModels
    aiProvider
    ssoApplication
    users
    ;
  visionModel = aiModels.${cfg.ai.visionModel} or null;
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
      assertion = aiProvider != null;
      message = "host.paperless.ai.providerHost must name a known NixOS host.";
    }
    {
      assertion = aiProvider != null && aiProvider.host.realm == config.host.realm;
      message = "Paperless AI and its Ollama provider must be in the same realm.";
    }
    {
      assertion = aiProvider != null && aiProvider.host.ollama != null;
      message = "The selected Paperless AI provider must enable Ollama.";
    }
    {
      assertion = builtins.hasAttr cfg.ai.textModel aiModels;
      message = "host.paperless.ai.textModel must select a model advertised by the Ollama provider.";
    }
    {
      assertion = visionModel != null;
      message = "host.paperless.ai.visionModel must select a model advertised by the Ollama provider.";
    }
    {
      assertion = visionModel != null && builtins.elem "vision" visionModel.capabilities;
      message = "host.paperless.ai.visionModel must advertise the vision capability.";
    }
  ];
}
