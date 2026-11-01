{
  fleetInventory,
  lib,
  nixosConfigurations,
}:
let
  hosts = lib.filterAttrs (
    _: configuration:
    let
      cfg = configuration.config.host.vikunja;
    in
    cfg != null && cfg.bots != { }
  ) nixosConfigurations;
  permissions = {
    read = 0;
    read-write = 1;
    admin = 2;
  };
in
lib.mapAttrs (
  host: configuration:
  lib.mapAttrs (
    name: bot:
    assert lib.assertMsg (builtins.all (
      seat: builtins.hasAttr seat fleetInventory.hosts
    ) bot.seats) "Vikunja bot ${host}/${name} references an unknown seat";
    {
      server = configuration.config.services.vikunja.settings.service.publicurl;
      bot = {
        inherit (bot) username;
        name = bot.displayName;
      };
      projects = lib.mapAttrsToList (title: permission: {
        inherit title;
        permission = permissions.${permission};
      }) bot.projects;
      token = {
        inherit (bot.token) title permissions;
        expires_at = bot.token.expiresAt;
      };
      state = {
        inherit host;
        realm = fleetInventory.hosts.${host}.realm;
        key = "agents/vikunja/${host}/${name}/credentials";
      };
      seats = lib.genAttrs bot.seats (seat: {
        realm = fleetInventory.hosts.${seat}.realm;
        key = "agents/vikunja/${host}/${name}/authorization";
      });
    }
  ) configuration.config.host.vikunja.bots
) hosts
