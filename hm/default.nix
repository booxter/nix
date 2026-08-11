{
  hostSpec,
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  inherit (osConfig.host) isDarwin isDesktop;
  developerToolsCfg = osConfig.host.userEnvironment.features.developerTools;
  firefoxCfg = osConfig.host.userEnvironment.features.firefox;
  localAiCfg = osConfig.host.userEnvironment.features.localAi;
  nvidiaDevelopmentCfg = osConfig.host.userEnvironment.features.nvidiaDevelopment;
  podmanDesktopCfg = osConfig.host.userEnvironment.features.podmanDesktop;
  sshCfg = osConfig.host.userEnvironment.features.ssh;
  hmFull = hostSpec.hmFull or true;
  username = osConfig.host.username;
in
{
  imports = [
    ./_mixins/password-store
    ./_mixins/podman-machine
    ./_mixins/xquartz
    ./_mixins/zsh
  ]
  ++ lib.optionals sshCfg.enable [
    ./_mixins/ssh
  ]
  ++ lib.optionals (developerToolsCfg.enable && developerToolsCfg.commandLine.enable) [
    ./_mixins/cli
  ]
  ++ lib.optionals hmFull [
    ./_mixins/remote-control
    ./_mixins/agents
    ./_mixins/podman
    ./_mixins/scm
    ./_mixins/security
  ]
  ++ lib.optionals (hmFull && developerToolsCfg.enable && developerToolsCfg.editor.enable) [
    ./_mixins/nixvim
  ]
  ++ lib.optionals (hmFull && developerToolsCfg.enable && developerToolsCfg.tmux.enable) [
    ./_mixins/tmux
  ]
  ++ lib.optionals isDesktop [
    ./_mixins/aerospace
    ./_mixins/email
    ./_mixins/fonts
    ./_mixins/jankyborders
    ./_mixins/kitty
    ./_mixins/sketchybar
  ]
  ++ lib.optionals (isDesktop && !isDarwin) [
    ./_mixins/hyprland
  ]
  ++ lib.optionals isDesktop [
    ./_mixins/spicetify
  ]
  ++ lib.optionals firefoxCfg.enable [
    ./_mixins/firefox
  ]
  ++ lib.optionals nvidiaDevelopmentCfg.enable [
    ./_mixins/krew
    ./_mixins/nv
  ];

  assertions = [
    {
      assertion = (!isDesktop) || hmFull;
      message = "`isDesktop = true` requires `hmFull = true`.";
    }
  ];

  home = {
    inherit username;
    homeDirectory = if isDarwin then "/Users/${username}" else "/home/${username}";
  };

  programs.home-manager.enable = true; # let it manage itself
  programs.podman-machine = {
    enable = osConfig.host.userEnvironment.features.podmanMachine.enable;
    provider = "libkrun";
    cpus = 4;
    memoryMiB = 8192;
    diskSizeGiB = 100;
    autoStart = true;
  };
  targets.darwin.copyApps.enable = isDarwin; # populate apps dir for Spotlight

  home.packages =
    with pkgs;
    [
    ]
    ++ lib.optionals isDesktop [
      element-desktop
      obsidian
      telegram-desktop
      wireshark
    ]
    ++ lib.optional podmanDesktopCfg.enable podman-desktop
    ++ lib.optionals (localAiCfg.enable && localAiCfg.ramalama.enable) [
      ramalama
    ];
}
