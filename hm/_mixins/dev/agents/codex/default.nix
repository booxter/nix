{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.codex;
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  mcps = import ./mcp.nix {
    inherit
      config
      lib
      osConfig
      ;
  };
  shared = import ../shared.nix { inherit lib osConfig; };
  codexContext = shared.context + mcps.instructions;
  # Follow the configured Codex version and preserve its voice prompt. Overrides
  # bypass Codex's first-name substitution, so render that placeholder here.
  voicePrompt =
    let
      rendered =
        lib.replaceStrings
          [ "{{ user_first_name }}" ]
          [ (builtins.head (lib.splitString " " config.host.hm.fullName)) ]
          (
            builtins.readFile "${config.programs.codex.package.src}/codex-rs/prompts/templates/realtime/backend_prompt.md"
          );
    in
    # Codex sends overrides verbatim. Fail on new or renamed upstream placeholders
    # so upgrades cannot silently send unresolved template variables to the model.
    assert lib.assertMsg (
      !(lib.hasInfix "{{" rendered || lib.hasInfix "}}" rendered)
    ) "Codex voice prompt contains unhandled template placeholders; update its substitutions.";
    rendered;
  oauthServerNames = builtins.attrNames (
    lib.filterAttrs (_: server: server.oauth != null) config.host.hm.dev.agents.mcp.httpServers
  );
  codexMcpLogin = pkgs.codex-mcp-login.override {
    codex = config.programs.codex.package;
    serverNames = oauthServerNames;
  };
in
{
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

    home.file = lib.mkIf (config.host.hm.env.roles.developer && cfg.enable) (
      lib.mapAttrs' (
        name: source: lib.nameValuePair ".agents/skills/${name}" { inherit source; }
      ) shared.skills
    );

    host.hm.sketchybar.codex.enable = lib.mkDefault (
      isDarwin && cfg.enable && config.host.hm.sketchybar.enable
    );

    programs.codex = lib.mkIf (config.host.hm.env.roles.developer && cfg.enable) {
      enable = true;
      context = codexContext;

      settings = {
        model = "gpt-5.6-sol";
        model_reasoning_effort = "high";
        personality = "pragmatic";
        experimental_realtime_ws_backend_prompt = voicePrompt + ''

          Speak at a noticeably faster pace, with shorter pauses, while remaining clear.
          Maintain this pace throughout the conversation.
        '';
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
