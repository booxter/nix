{
  config,
  facts,
  ...
}:
let
  cfg = config.host.attic;
  realmAttic = facts.realms.${config.host.realm}.services.attic or null;
in
{
  config.assertions = [
    {
      assertion = !cfg.client.enable || realmAttic != null;
      message = "realm '${config.host.realm}' does not define an Attic service";
    }
    {
      assertion = !cfg.server.enable || realmAttic != null;
      message = "Attic servers must belong to a realm that defines an Attic service";
    }
  ];
}
