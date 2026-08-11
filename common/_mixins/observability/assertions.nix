{ config, facts, ... }:
let
  realmObservability = facts.realms.${config.host.realm}.services.observability or null;
in
{
  assertions = [
    {
      assertion = !config.host.observability.enable || realmObservability != null;
      message = "realm '${config.host.realm}' does not define observability services";
    }
  ];
}
