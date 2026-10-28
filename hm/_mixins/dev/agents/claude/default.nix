{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  shared = import ../shared.nix { inherit config lib osConfig; };
  models = {
    default = "opus";
    implementer = "sonnet";
    specialist = "fable";
  };
  mcps = import ../mcp.nix { inherit config lib osConfig; };
  hasMcpSecrets = mcps.requiredSecrets != [ ];

  statusLine = pkgs.callPackage ./statusline { };
in
{
  imports = [ ./mutable-settings.nix ];

  programs.claude-code =
    lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.claude.enable)
      {
        enable = true;
        mutableSettings = true;
        context = shared.context models + mcps.instructions;
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
            ANTHROPIC_MODEL = models.default;
            CLAUDE_CODE_EFFORT_LEVEL = "high";
            CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = "2";
            CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = "1";
          };
          editorMode = "vim";
          # Draw with the terminal palette, which Stylix themes, as Codex does.
          theme = "dark-ansi";
          statusLine = {
            type = "command";
            command = lib.getExe statusLine;
          };
          pluginConfigs."cc-plugin-agents-md@builtin".options.instructionFiles = "claude-md-and-agents-md";
        };
      };
}
