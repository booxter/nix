{
  config,
  inputs,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  codexPkgs = import ./pkgs { inherit pkgs; };
  codexDesktopLinuxPackage =
    (inputs.codex-desktop-linux.packages.${pkgs.stdenv.hostPlatform.system}.codex-desktop.override {
      enableComputerUseUi = true;
      linuxFeatureIds = [ "remote-mobile-control" ];
    }).overrideAttrs
      (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.asar ];
        # The remote-mobile-control patch mistakes the function-local
        # __codexChild binding from the external-open patch for a module-level
        # child_process binding. Repair its one global use until upstream fixes
        # the patch interaction; --replace-fail makes upstream drift explicit.
        postInstall = (old.postInstall or "") + ''
          resources="$out/opt/codex-desktop/resources"
          extracted="$TMPDIR/codex-desktop-app-fixed"
          asar extract "$resources/app.asar" "$extracted"
          mainBundle="$(find "$extracted/.vite/build" -maxdepth 1 -name 'main-*.js' -print -quit)"
          substituteInPlace "$mainBundle" \
            --replace-fail '__codexChild.spawn(codexLinuxRemoteControlFlockPath' \
              'require(`node:child_process`).spawn(codexLinuxRemoteControlFlockPath'

          rm -f "$resources/app.asar"
          rm -rf "$resources/app.asar.unpacked"
          (cd "$extracted" && find . -type f | LC_ALL=C sort | sed 's#^./##') \
            > "$TMPDIR/codex-desktop-app-fixed.ordering"
          asar pack "$extracted" "$resources/app.asar" \
            --ordering "$TMPDIR/codex-desktop-app-fixed.ordering" \
            --unpack "{*.node,*.so,*.dylib}"
        '';
      });
  claudeModel = "opus";
  modelEffort = "high";
  agentContext = ''
    This machine uses Nix on macOS or Linux. If a required tool is missing,
    prefer repository flake apps or dev shells; otherwise use
    `nix shell nixpkgs#<package> -c <command>` instead of installing it globally.
    Nix builders for x86_64-linux and aarch64-darwin are available for
    cross-platform builds.
  '';
  codexContext = agentContext + ''
    Only use the Firefox DevTools MCP when the user explicitly requests browser
    interaction or browser-based debugging.
  '';
  codingAgentEnv = {
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
  imports = [
    inputs.codex-desktop-linux.homeManagerModules.default
    ./codex-warmer.nix
  ];

  programs.codexDesktopLinux = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    enable = true;
    cliPackage = config.programs.codex.package;
    package = codexDesktopLinuxPackage;
    # The patched Desktop app-server is the remote-control owner. A separate
    # remoteControl service races it for the same backend environment and makes
    # Desktop pairing fail with HTTP 409 "Remote app server already online".
  };

  # The remote-mobile-control Linux device-key provider rejects outbound
  # authorization unless this directory is exactly 0700, but the app creates
  # it as 0755. Keep the correction declarative until upstream fixes creation.
  systemd.user.tmpfiles.rules = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    "d %h/.config/codex-desktop 0700 - - -"
  ];

  programs.codex = {
    enable = true;
    context = codexContext;

    settings = {
      model = "gpt-5.6-sol";
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
      tui.vim_mode_default = true;
      tui.status_line = [
        "model-with-reasoning"
        "current-dir"
        "context-remaining"
      ];
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
    context = agentContext;

    settings = {
      outputStyle = "Proactive";
      editorMode = "vim";
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

  home.packages =
    lib.optionals (!isWork) [
      codexPkgs.codex-usage-status
      codexPkgs.codex-rate-limit-reset-credits
    ]
    ++ lib.optionals isWork [
      codexPkgs.codex-work-usage-status
    ];

  # Work remote settings pin the default model and effort; user settings lose to
  # that managed layer, but CLI flags still win for shell launches.
  home.shellAliases = lib.optionalAttrs isWork {
    claude = "command claude --model ${claudeModel} --effort ${modelEffort}";
  };
}
