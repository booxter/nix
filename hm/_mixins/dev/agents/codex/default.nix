{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.codex;
  secretValueType = lib.types.either lib.types.nonEmptyStr (
    lib.types.submodule {
      options.secret = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SOPS secret containing the MCP configuration value.";
      };
    }
  );
  stdioServerType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Executable used to start the stdio MCP server.";
      };
      args = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Arguments passed to the MCP server executable.";
      };
      env = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        description = "Environment variables passed to the MCP server.";
      };
      instructions = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Default agent instructions for using the MCP server.";
      };
    };
  };
  httpServerType = lib.types.submodule {
    options = {
      url = lib.mkOption {
        type = secretValueType;
        description = "Public URL or SOPS-backed URL for the HTTP MCP server.";
      };
      oauth = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options.clientId = lib.mkOption {
              type = lib.types.nullOr secretValueType;
              default = null;
              description = "Public or SOPS-backed OAuth client ID.";
            };
          }
        );
        default = null;
        description = "OAuth configuration, or null for an unauthenticated HTTP server.";
      };
      startupTimeoutSec = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Seconds to wait for the MCP server to initialize.";
      };
      instructions = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Default agent instructions for using the MCP server.";
      };
    };
  };
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  mcps = import ./mcp.nix {
    inherit
      config
      lib
      osConfig
      pkgs
      ;
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
  codexContext = agentContext + mcps.instructions;
  oauthServerNames = builtins.attrNames (
    lib.filterAttrs (_: server: server.oauth != null) cfg.mcp.httpServers
  );
  codexMcpLogin = pkgs.codex-mcp-login.override {
    codex = config.programs.codex.package;
    serverNames = oauthServerNames;
  };
in
{
  imports = [ ./codex-warmer.nix ];

  options.host.hm.dev.codex.mcp = {
    stdioServers = lib.mkOption {
      type = lib.types.attrsOf stdioServerType;
      default = { };
      description = "Stdio MCP servers contributed to Codex by this host.";
    };
    httpServers = lib.mkOption {
      type = lib.types.attrsOf httpServerType;
      default = { };
      description = "HTTP MCP servers contributed to Codex by this host.";
    };
    requiredSecrets = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = mcps.requiredSecrets;
      readOnly = true;
      internal = true;
      description = "SOPS secrets required by configured Codex MCP servers.";
    };
  };

  config = {
    home.packages =
      lib.optionals (config.host.hm.env.roles.developer && cfg.enable && oauthServerNames != [ ]) [
        codexMcpLogin
      ]
      ++ lib.optional (
        config.host.hm.env.roles.developer
        && cfg.enable
        && osConfig.host.desktop != null
        && lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.chatgpt
      ) pkgs.chatgpt;

    home.file.".agents/skills/weekly-report" =
      lib.mkIf (config.host.hm.env.roles.developer && cfg.enable && osConfig.host.realm == "work")
        {
          source = ./skills/weekly-report;
        };

    host.hm.sketchybar.codex.enable = lib.mkDefault (
      isDarwin && cfg.enable && config.host.hm.sketchybar.enable
    );

    assertions = [
      {
        assertion = !cfg.usage.warmer.enable || cfg.usage.account == "personal";
        message = "host.hm.dev.codex.usage.warmer is only supported for personal accounts.";
      }
    ];

    programs.codex = lib.mkIf (config.host.hm.env.roles.developer && cfg.enable) {
      enable = true;
      context = codexContext;

      settings = {
        model = "gpt-5.6-sol";
        model_reasoning_effort = "high";
        personality = "pragmatic";
        approvals_reviewer = "auto_review";
        desktop.keepRemoteControlAwakeWhilePluggedIn = true;
        mcp_servers = mcps.settings;
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
  };
}
