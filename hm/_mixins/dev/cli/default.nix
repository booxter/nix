{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  cfg = osConfig.host.userEnvironment.features.dev;
  podmanCfg = config.host.hm.podman;
  cliPkgs = import ./pkgs { inherit pkgs; };
  # On macOS, act connects through the forwarded host socket, but job
  # containers need the VM-internal socket with SELinux labeling disabled.
  actPodmanArgs = lib.optionalString isDarwin (
    " --container-daemon-socket=unix:///run/user/$UID/podman/podman.sock"
    + " --container-options=--security-opt=label=disable"
  );
in
lib.mkIf (cfg.enable && cfg.cli.enable) {
  home.packages = with pkgs; [
    act
    delve
    devenv
    cliPkgs.gh-restart-failed-jobs
    go
    (lima.override { withAdditionalGuestAgents = true; })
    pre-commit
    python313
  ];

  home.shellAliases = lib.mkIf podmanCfg.enable {
    # remove once https://github.com/nektos/act/issues/2329 is fixed
    act = "act -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04${actPodmanArgs}";
  };
}
