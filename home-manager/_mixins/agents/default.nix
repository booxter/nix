{
  config,
  lib,
  pkgs,
  isDarwin,
  isWork,
  ...
}:
let
  codexPkgs = import ./pkgs { inherit pkgs; };
  claudeModel = "opus";
  modelEffort = "xhigh";
  codingAgentEnv = lib.optionalAttrs isDarwin {
    inherit (config.home.sessionVariables) SSH_ASKPASS;
    SSH_ASKPASS_REQUIRE = "force";
  };
  trustedProjects =
    paths:
    lib.genAttrs (map (path: "${config.home.homeDirectory}/${path}") paths) (_: {
      trust_level = "trusted";
    });
in
{
  programs.codex = {
    enable = true;

    settings = {
      model = "gpt-5.5";
      model_reasoning_effort = modelEffort;
      personality = "pragmatic";
      approvals_reviewer = "auto_review";
      notice.fast_default_opt_out = true;

      projects = trustedProjects [
        "src/sdn"
        "src/nix"
        "src/nixpkgs"
        "src/ovn-kubernetes"
      ];

      # Avoid accidental bare-Esc interrupts until Codex has safer interrupt UX:
      # https://github.com/openai/codex/issues/12582
      # https://github.com/openai/codex/issues/14509
      tui.keymap.chat.interrupt_turn = "f12";
    }
    // lib.optionalAttrs (codingAgentEnv != { }) {
      shell_environment_policy.set = codingAgentEnv;
    }
    // lib.optionalAttrs (!isWork) {
      mcp_servers.firefox-devtools = {
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
  };

  programs.claude-code = {
    enable = true;

    settings = {
      outputStyle = "Proactive";
      fastModePerSessionOptIn = true;

      permissions = {
        defaultMode = "auto";
        disableBypassPermissionsMode = "disable";
      };

      autoMode.soft_deny = [
        "$defaults"
        "Never push, deploy, or change managed hosts unless explicitly asked."
      ];
    }
    // lib.optionalAttrs (!isWork) {
      model = claudeModel;
      effortLevel = modelEffort;
    }
    // lib.optionalAttrs (codingAgentEnv != { }) {
      env = codingAgentEnv;
    };
  };

  home.packages = lib.optionals (!isWork) [
    codexPkgs.codex-usage-status
    codexPkgs.codex-rate-limit-reset-credits
  ];

  # Work remote settings pin the default model and effort; user settings lose to
  # that managed layer, but CLI flags still win for shell launches.
  home.shellAliases = lib.optionalAttrs isWork {
    claude = "command claude --model ${claudeModel} --effort ${modelEffort}";
  };
}
