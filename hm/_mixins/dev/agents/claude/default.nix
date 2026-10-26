{
  config,
  lib,
  osConfig,
  ...
}:
let
  shared = import ../shared.nix { inherit config lib osConfig; };
  mcps = import ../mcp.nix { inherit config lib osConfig; };
  hasMcpSecrets = mcps.requiredSecrets != [ ];
in
{
  imports = [ ./mutable-settings.nix ];

  programs.claude-code =
    lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.claude.enable)
      {
        enable = true;
        mutableSettings = true;
        context = shared.context + mcps.instructions;
        skills = shared.skills;

        # Home Manager wraps Claude with --plugin-dir. Secret-backed servers use
        # a SOPS-rendered runtime plugin instead of embedding values in the store.
        plugins = lib.optional hasMcpSecrets "/etc/claude-code";
        mcpServers = lib.mkIf (!hasMcpSecrets) (import ./mcp.nix { inherit lib mcps; });

        settings = {
          attribution = {
            commit = "";
            pr = "";
          };
          env = shared.environment // {
            DISABLE_AUTOUPDATER = "1";
            ANTHROPIC_MODEL = "opus";
          };
          pluginConfigs."cc-plugin-agents-md@builtin".options.instructionFiles = "claude-md-and-agents-md";
        };
      };
}
