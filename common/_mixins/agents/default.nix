{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  codexConfig = hmConfig.programs.codex;
  claudeConfig = hmConfig.programs.claude-code;
  codexHome = hmConfig.home.sessionVariables.CODEX_HOME or "${hmConfig.home.homeDirectory}/.codex";
  codexConfigFile = lib.removePrefix "${hmConfig.home.homeDirectory}/" "${codexHome}/config.toml";
  mcpSecrets = hmConfig.host.hm.dev.agents.mcp.requiredSecrets;
  hasMcpSecrets = mcpSecrets != [ ];
  generatedCodexConfig = (pkgs.formats.toml { }).generate "codex-system-config" codexConfig.settings;
  mcps = import ../../../hm/_mixins/dev/agents/mcp.nix {
    config = hmConfig;
    osConfig = config;
    inherit lib;
  };
  claudeServers = import ../../../hm/_mixins/dev/agents/claude/mcp.nix { inherit lib mcps; };
in
{
  config = {
    environment.etc."codex/config.toml" = lib.mkIf codexConfig.enable {
      source =
        if hasMcpSecrets then config.sops.templates."codex-config.toml".path else generatedCodexConfig;
    };

    sops = lib.mkIf ((codexConfig.enable || claudeConfig.enable) && hasMcpSecrets) {
      secrets = lib.genAttrs mcpSecrets (_: { });
      templates."codex-config.toml" = lib.mkIf codexConfig.enable {
        owner = username;
        file = generatedCodexConfig;
      };
      templates."claude-mcp-plugin.json" = lib.mkIf claudeConfig.enable {
        owner = username;
        content = builtins.toJSON {
          name = "home-manager-mcp";
          mcpServers = claudeServers;
        };
      };
    };

    environment.etc."claude-code/.claude-plugin/plugin.json" =
      lib.mkIf (claudeConfig.enable && hasMcpSecrets)
        {
          source = config.sops.templates."claude-mcp-plugin.json".path;
        };

    # Keep Codex's user config writable. Declarative settings are loaded from the
    # lower-precedence system layer, while the app and CLI own the user layer.
    home-manager.users.${username}.home.file.${codexConfigFile} = lib.mkIf codexConfig.enable {
      enable = lib.mkForce false;
    };
  };
}
