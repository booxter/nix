{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.act;
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  # On macOS, act connects through the forwarded host socket, but job
  # containers need the VM-internal socket with SELinux labeling disabled.
  podmanArgs = lib.optionalString (isDarwin && config.programs.podman-machine.enable) (
    " --container-daemon-socket=unix:///run/user/$UID/podman/podman.sock"
    + " --container-options=--security-opt=label=disable"
  );
in
{
  options.host.hm.dev.act.enable = lib.mkEnableOption "Act GitHub Actions runner";

  config = lib.mkIf (config.host.hm.env.roles.developer && cfg.enable) {
    host.hm.podman = {
      enable = lib.mkDefault true;
      api.enable = lib.mkDefault true;
    };

    home.packages = [ pkgs.act ];

    home.shellAliases = {
      # remove once https://github.com/nektos/act/issues/2329 is fixed
      act = "act -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04${podmanArgs}";
    };
  };
}
