{
  config,
  isDesktop,
  isLinux,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  codexPkgs = import ./pkgs { inherit pkgs; };
  claudeModel = "opus";
  modelEffort = "high";
  deployFirefoxDevtoolsMcp = !isWork;
  nixosMcpServer = {
    command = lib.getExe pkgs.mcp-nixos;
    args = [ ];
  };
  codexMcpServers = {
    nixos = nixosMcpServer;
  }
  // lib.optionalAttrs deployFirefoxDevtoolsMcp {
    firefox-devtools = {
      command = lib.getExe pkgs.firefox-devtools-mcp;
      args = [
        "--profile-path"
        "${config.xdg.dataHome}/firefox-devtools-mcp"
        "--accept-insecure-certs"
        "--viewport"
        "1440x1000"
      ];
    };
  };
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
    - When an AI agent creates or materially contributes to a commit, add an
      `Assisted-by: <tool> <model> <effort>` trailer with the tool's recognizable
      product name and the session's model and reasoning effort, such as
      `Assisted-by: Codex gpt-5.6-sol xhigh` or
      `Assisted-by: Claude Code opus-4.8 high`.
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
  codexContext =
    agentContext
    + lib.optionalString deployFirefoxDevtoolsMcp ''
      Only use the Firefox DevTools MCP when the user explicitly requests browser
      interaction or browser-based debugging.
    '';
  codingAgentEnv = {
    inherit (config.home.sessionVariables) SSH_ASKPASS;
    SSH_ASKPASS_REQUIRE = "force";
  };
  codexConfigDir =
    if config.home.preferXdgDirectories then
      "${lib.removePrefix config.home.homeDirectory config.xdg.configHome}/codex"
    else
      ".codex";
in
{
  imports = [
    ./codex-warmer.nix
  ]
  ++ lib.optionals (isDesktop && isLinux) [
    ./codex-app.nix
  ];

  programs.codex = {
    enable = true;
    context = codexContext;

    settings = {
      model = "gpt-5.6-sol";
      model_reasoning_effort = modelEffort;
      personality = "pragmatic";
      approvals_reviewer = "auto_review";
      mcp_oauth_credentials_store = "file";
      notice.fast_default_opt_out = true;

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
      mcp_servers = codexMcpServers;
    }
    // lib.optionalAttrs (codingAgentEnv != { }) {
      shell_environment_policy.set = codingAgentEnv;
    };
  };

  programs.claude-code = lib.mkIf isWork {
    enable = true;
    context = agentContext;
    mcpServers.nixos = nixosMcpServer;

    settings = {
      outputStyle = "Proactive";
      editorMode = "vim";
      fastModePerSessionOptIn = true;

      permissions = {
        defaultMode = "auto";
        disableBypassPermissionsMode = "disable";
      };
    }
    // lib.optionalAttrs (codingAgentEnv != { }) {
      env = codingAgentEnv;
    };
  };

  home.packages =
    lib.optionals (!isWork) [
      codexPkgs.codex-usage-status
      codexPkgs.codex-rate-limit-reset-credits
    ]
    ++ lib.optionals isWork [
      codexPkgs.codex-mcp-init
      codexPkgs.codex-work-usage-status
    ];

  # Preserve edits made by the removed local-overlay patch. Run after Home
  # Manager removes its old config.toml symlink, and never replace a user file.
  home.activation.migrateCodexLocalConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    localConfig="$HOME/${codexConfigDir}/config.local.toml"
    userConfig="$HOME/${codexConfigDir}/config.toml"

    if [[ -f "$localConfig" && ! -e "$userConfig" && ! -L "$userConfig" ]]; then
      verboseEcho "Moving $localConfig to writable Codex user config $userConfig"
      run mv $VERBOSE_ARG "$localConfig" "$userConfig"
    fi
  '';

  # Work remote settings pin the default model and effort; user settings lose to
  # that managed layer, but CLI flags still win for shell launches.
  home.shellAliases = lib.optionalAttrs isWork {
    claude = "command claude --model ${claudeModel} --effort ${modelEffort}";
  };
}
