{
  config,
  lib,
  ...
}:
let
  cfg = config.host.home-assistant;
  homeAssistantSso = config.host.sso.applications.home-assistant;
  bootstrapOwner = config.host.sso.users.${homeAssistantSso.bootstrapOwner};
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem homeAssistantSso.roles.admin bootstrapOwner.groups;
        message = "The Home Assistant bootstrap owner must belong to its SSO admin group.";
      }
      {
        assertion = builtins.elem homeAssistantSso.roles.user bootstrapOwner.groups;
        message = "The Home Assistant bootstrap owner must belong to its SSO user group.";
      }
    ];
  };
}
