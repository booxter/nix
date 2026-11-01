{ lib, nixosConfigurations }:
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
  _: configuration:
  lib.mapAttrs (_: bot: {
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
  }) configuration.config.host.vikunja.bots
) hosts
