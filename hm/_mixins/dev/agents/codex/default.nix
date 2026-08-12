{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  cfg = config.host.hm.dev.codex;
  inherit (osConfig.host) isDarwin;
  hasOauthHttpMcp = lib.any (server: server.http != null && server.http.auth == "oauth") (
    builtins.attrValues osConfig.host.mcp.pool
  );
  mcps = import ./mcp.nix { inherit lib osConfig; };
  codexPkgs = import ./pkgs {
    inherit pkgs;
    codex = config.programs.codex.package;
  };
  agentContext = ''
    This machine uses Nix. Use it to access tools that are not installed. Never
    install tools permanently. Use remote builders for other platforms.

    Never push, post, deploy, or change managed hosts unless user explicitly
    asks. Before posting to web, show user exact contents and get confirmation.

    Follow repo existing commit message style. Never bypass commit-message
    validation with `--no-verify` or disable commit message hook.

    When creating pull requests, keep description terse. No headings and
    boilerplate such as Summary, Validation, or Testing. No slop. Be brief.
  '';
  codexContext = agentContext + osConfig.host.mcp.instructions;
in
{
  imports = [ ./codex-warmer.nix ];

  host.hm.sketchybar.codex.enable = lib.mkDefault (
    isDarwin && cfg.enable && config.host.hm.sketchybar.enable
  );

  assertions = [
    {
      assertion = !cfg.usage.warmer.enable || cfg.usage.account == "personal";
      message = "host.hm.dev.codex.usage.warmer is only supported for personal accounts.";
    }
  ];

  programs.codex = lib.mkIf (devCfg.enable && cfg.enable) {
    enable = true;
    context = codexContext;

    settings = {
      model = "gpt-5.6-sol";
      model_reasoning_effort = "high";
      personality = "pragmatic";
      approvals_reviewer = "auto_review";
      desktop.keepRemoteControlAwakeWhilePluggedIn = true;
      mcp_servers = mcps;
      mcp_oauth_credentials_store = "file";
      notice.fast_default_opt_out = true;

      tui.theme = "gruvbox-dark";
      # Avoid accidental bare-Esc interrupts until Codex has safer interrupt UX:
      # https://github.com/openai/codex/issues/12582
      # https://github.com/openai/codex/issues/14509
      tui.keymap.chat.interrupt_turn = "f12";
      tui.vim_mode_default = true;
      tui.status_line = [
        "model-with-reasoning"
        "current-dir"
        "context-remaining"
      ];
      shell_environment_policy.set = {
        inherit (config.home.sessionVariables) SSH_ASKPASS;
        SSH_ASKPASS_REQUIRE = "force";
      };
    };
  };

  home.packages = lib.optionals (devCfg.enable && cfg.enable && hasOauthHttpMcp) [
    codexPkgs.codex-mcp-init
  ];
}
