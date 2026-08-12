{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  containersCfg = osConfig.host.userEnvironment.features.containers;
  podmanMachine = config.programs.podman-machine;
  podmanPackage = if isDarwin then podmanMachine.package else pkgs.podman;
  podmanSocket =
    if isDarwin then
      "unix://$TMPDIR/podman/${podmanMachine.name}-api.sock"
    else
      "unix://$XDG_RUNTIME_DIR/podman/podman.sock";
in
lib.mkIf containersCfg.enable {
  home = {
    # programs.podman-machine owns the package when it manages a Darwin VM.
    packages =
      lib.optionals (!(isDarwin && podmanMachine.enable)) [ podmanPackage ]
      ++ lib.optional containersCfg.desktop.enable pkgs.podman-desktop
      ++ lib.optional isDarwin pkgs.container;

    sessionVariables = {
      DOCKER_HOST = podmanSocket;
    }
    // lib.optionalAttrs isDarwin {
      CONTAINERS_MACHINE_PROVIDER = podmanMachine.provider;
    };

  };

  # Keep the rootless Docker-compatible API socket available through systemd.
  systemd.user.services.podman = lib.mkIf (!isDarwin) {
    Unit = {
      Description = "Podman API Service";
      Requires = [ "podman.socket" ];
      After = [ "podman.socket" ];
    };

    Service = {
      Delegate = true;
      Type = "exec";
      KillMode = "process";
      ExecStart = "${lib.getExe podmanPackage} system service";
    };
  };

  systemd.user.sockets.podman = lib.mkIf (!isDarwin) {
    Unit.Description = "Podman API Socket";

    Socket = {
      ListenStream = "%t/podman/podman.sock";
      SocketMode = "0660";
    };

    Install.WantedBy = [ "sockets.target" ];
  };
}
