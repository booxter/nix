{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  podmanMachine = config.programs.podman-machine;
  podmanPackage = if isDarwin then podmanMachine.package else pkgs.podman;
  podmanSocket =
    if isDarwin then
      "unix://$TMPDIR/podman/${podmanMachine.name}-api.sock"
    else
      "unix://$XDG_RUNTIME_DIR/podman/podman.sock";
  # On macOS, act connects through the forwarded host socket, but job
  # containers need the VM-internal socket with SELinux labeling disabled.
  actPodmanArgs = lib.optionalString (isDarwin && podmanMachine.enable) (
    " --container-daemon-socket=unix:///run/user/$UID/podman/podman.sock"
    + " --container-options=--security-opt=label=disable"
  );
in
{
  home = {
    # programs.podman-machine owns the package when it manages a Darwin VM;
    # Docker Desktop supplies the container engine when that feature is off.
    packages = lib.optionals (!isDarwin) [ podmanPackage ];

    sessionVariables =
      lib.optionalAttrs (!isDarwin || podmanMachine.enable) {
        DOCKER_HOST = podmanSocket;
      }
      // lib.optionalAttrs (isDarwin && podmanMachine.enable) {
        CONTAINERS_MACHINE_PROVIDER = podmanMachine.provider;
      };

    shellAliases = {
      # remove once https://github.com/nektos/act/issues/2329 is fixed
      act = "act -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04${actPodmanArgs}";
    };
  };

  # act uses the Docker Engine API instead of invoking a container-engine CLI.
  # Podman Machine provides and forwards that API on macOS; on Linux, keep the
  # rootless Docker-compatible API socket available through systemd.
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
