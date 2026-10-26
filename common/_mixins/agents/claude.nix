{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  hasMcpSecrets = hmConfig.host.hm.dev.agents.mcp.requiredSecrets != [ ];
  mcps = import ../../../hm/_mixins/dev/agents/mcp.nix {
    config = hmConfig;
    osConfig = config;
    inherit lib;
  };
  servers = import ../../../hm/_mixins/dev/agents/claude/mcp.nix { inherit lib mcps; };
in
{
  config = lib.mkIf (hmConfig.programs.claude-code.enable && hasMcpSecrets) {
    sops.templates."claude-mcp-plugin.json" = {
      owner = username;
      content = builtins.toJSON {
        name = "home-manager-mcp";
        mcpServers = servers;
      };
    };

    environment.etc."claude-code/.claude-plugin/plugin.json".source =
      config.sops.templates."claude-mcp-plugin.json".path;
  };
}
