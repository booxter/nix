{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.home-assistant;
  homeAssistantSso = facts.sso.applications.home-assistant;
  bootstrapOwner = facts.sso.users.${homeAssistantSso.bootstrapOwner};
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem homeAssistantSso.adminGroup bootstrapOwner.groups;
        message = "The Home Assistant bootstrap owner must belong to its SSO admin group.";
      }
      {
        assertion = builtins.elem homeAssistantSso.userGroup bootstrapOwner.groups;
        message = "The Home Assistant bootstrap owner must belong to its SSO user group.";
      }
    ];
  };
}
