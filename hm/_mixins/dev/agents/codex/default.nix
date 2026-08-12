{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  codexCfg = devCfg.agents.codex;
  hasOauthHttpMcp = lib.any (server: server.http != null && server.http.auth == "oauth") (
    builtins.attrValues osConfig.host.mcp.pool
  );
  mcps = import ./mcp.nix { inherit lib osConfig; };
  codexPkgs = import ./pkgs {
    inherit pkgs;
    codex = config.programs.codex.package;
  };
  mcpInstructions = lib.concatMapStringsSep "\n" (server: server.instructions) (
    lib.filter (server: server.instructions != "") (builtins.attrValues osConfig.host.mcp.pool)
  );
  agentContext = ''
    This machine uses Nix on macOS or Linux. If a required tool is missing,
    prefer repository flake apps or dev shells; otherwise use
    `nix shell nixpkgs#<package> -c <command>` instead of installing it globally.
    Nix builders for x86_64-linux and aarch64-darwin are available for
    cross-platform builds.

    Never push, post, deploy, or change managed hosts unless the user
    explicitly asks. Before posting a bug report, show the user the exact
    contents and get their confirmation.

    When creating or amending Git commits:
    - Follow the repository's existing commit-message style.
    - Keep the subject at most 72 characters; prefer 50 or fewer when that
      remains clear.
    - Separate a body from the subject with a blank line.
    - Hard-wrap body prose at 72 characters. Hard-wrapping means inserting
      newline characters so each physical prose line is at most 72 characters;
      terminal or editor soft wrapping does not count.
    - Do not split URLs, literal code, long identifiers, or Git trailers solely
      to satisfy the limit.
    - For multiline messages, compose and validate the complete message in a
      file and use `git commit -F <file>` instead of a long `-m` argument.
    - Never bypass commit-message validation with `--no-verify` or disable the
      `commit-message-format` hook.
    - If validation fails, edit the saved message and run
      `git hook run commit-msg -- "$(git rev-parse --git-path COMMIT_EDITMSG)"`
      until it passes, then retry the commit once. Do not repeatedly create and
      amend commits while guessing at the format.

    When creating pull requests:
    - Keep descriptions terse: at most three bullets describing material changes.
    - Do not add headings or boilerplate sections such as Summary, Validation, or Testing.
    - Mention checks only when they failed, were skipped, or require reviewer action.
    - Do not restate the title or commit messages.
    - These rules override generic PR-body conventions from publishing workflows.
  '';
  codexContext = agentContext + mcpInstructions;
in
{
  imports = [ ./codex-warmer.nix ];

  programs.codex = lib.mkIf (devCfg.enable && codexCfg.enable) {
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

  home.packages = lib.optionals (devCfg.enable && codexCfg.enable && hasOauthHttpMcp) [
    codexPkgs.codex-mcp-init
  ];
}
