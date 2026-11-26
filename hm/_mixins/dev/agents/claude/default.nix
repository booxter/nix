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
  nativeSettings = lib.versionAtLeast lib.trivial.release "26.11";

  statusLine = pkgs.callPackage ./statusline { };
  worktree = lib.getExe (pkgs.callPackage ./worktree { });
  worktreeHook = subcommand: [
    {
      hooks = [
        {
          type = "command";
          command = "${worktree} ${subcommand}";
        }
      ];
    }
  ];
in
{
  # TODO(26.11): Remove the backport once all Home Manager hosts have migrated.
  imports = lib.optional (!nativeSettings) ./mutable-settings.nix;

  home.file."${config.programs.claude-code.configDir}/skills/fleet-mcp" =
    lib.mkIf (nativeSettings && config.programs.claude-code.enable && hasMcpSecrets)
      {
        source = config.lib.file.mkOutOfStoreSymlink "/etc/claude-code";
      };

  host.hm.sketchybar.claude.enable = lib.mkDefault (
    pkgs.stdenv.hostPlatform.isDarwin
    && config.programs.claude-code.enable
    && config.host.hm.sketchybar.enable
  );

  programs.claude-code =
    lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.claude.enable)
      {
        enable = true;
        mutableSettings = true;
        context = shared.context models + mcps.instructions;
        skills = shared.skills // {
          worktree = ./skills/worktree;
        };

        # Home Manager wraps Claude with --plugin-dir. Secret-backed servers use
        # a SOPS-rendered runtime plugin instead of embedding values in the store.
        plugins = lib.mkIf (!nativeSettings) (lib.optional hasMcpSecrets "/etc/claude-code");
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
          permissions = {
            allow = [ "WebFetch" ];
            defaultMode = "auto";
          };
          # Keep worktrees outside the repository on branches named as requested.
          hooks = {
            WorktreeCreate = worktreeHook "create";
            WorktreeRemove = worktreeHook "remove";
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
