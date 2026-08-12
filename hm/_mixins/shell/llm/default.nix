{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.ramalama;
in
{
  options.host.hm.ramalama.enable = lib.mkEnableOption "RamaLama";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.hm.podman.enable;
        message = "host.hm.ramalama requires host.hm.podman";
      }
    ];

    home.packages = [ pkgs.ramalama ];
    programs.podman-machine.provider = "libkrun";
  };
}
