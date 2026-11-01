{
  config,
  fleetInventory,
  lib,
  outputs,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  enabled = hmConfig.programs.codex.enable || hmConfig.programs.claude-code.enable;
  declarations = import ../../../apps/vikunja-provision/declarations.nix {
    inherit fleetInventory lib;
    inherit (outputs) nixosConfigurations;
  };
  servers = lib.concatMapAttrs (
    host: bots:
    lib.concatMapAttrs (
      name: bot:
      lib.optionalAttrs (builtins.hasAttr hostname bot.seats) {
        "vikunja-${host}-${name}" = {
          url = "${lib.removeSuffix "/" bot.server}/api/v2/mcp";
          headers.Authorization.secret = bot.seats.${hostname}.key;
        };
      }
    ) bots
  ) declarations;
in
{
  assertions = [
    {
      assertion = servers == { } || enabled;
      message = "Vikunja MCP seat ${hostname} must enable Codex or Claude.";
    }
  ];

  home-manager.users.${username}.host.hm.dev.agents.mcp.httpServers = servers;
}
