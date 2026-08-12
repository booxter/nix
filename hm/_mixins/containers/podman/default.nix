{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  cfg = config.host.hm.podman;
  podmanMachine = config.programs.podman-machine;
  podmanPackage = if isDarwin then podmanMachine.package else pkgs.podman;
  podmanSocket =
    if isDarwin then
      "unix://$TMPDIR/podman/${podmanMachine.name}-api.sock"
    else
      "unix://$XDG_RUNTIME_DIR/podman/podman.sock";
in
{
  options.host.hm.podman = {
    enable = lib.mkEnableOption "Podman container environment";
    api.enable = lib.mkEnableOption "Podman Docker-compatible API socket";
    desktop.enable = lib.mkEnableOption "Podman Desktop";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.api.enable || cfg.enable;
          message = "host.hm.podman.api requires host.hm.podman";
        }
        {
          assertion = !cfg.desktop.enable || cfg.enable;
          message = "host.hm.podman.desktop requires host.hm.podman";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      home = {
        # programs.podman-machine owns the package when it manages a Darwin VM.
        packages =
          lib.optionals (!(isDarwin && podmanMachine.enable)) [ podmanPackage ]
          ++ lib.optional cfg.desktop.enable pkgs.podman-desktop
          ++ lib.optional isDarwin pkgs.container;

        sessionVariables =
          lib.optionalAttrs cfg.api.enable {
            DOCKER_HOST = podmanSocket;
          }
          // lib.optionalAttrs isDarwin {
            CONTAINERS_MACHINE_PROVIDER = podmanMachine.provider;
          };
      };

      # Keep the rootless Docker-compatible API socket available through systemd.
      systemd.user.services.podman = lib.mkIf (!isDarwin && cfg.api.enable) {
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

      systemd.user.sockets.podman = lib.mkIf (!isDarwin && cfg.api.enable) {
        Unit.Description = "Podman API Socket";

        Socket = {
          ListenStream = "%t/podman/podman.sock";
          SocketMode = "0660";
        };

        Install.WantedBy = [ "sockets.target" ];
      };
    })
  ];
}
