{ config, lib, ... }:
{
  options.host.desktop.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.nixpkgs.hostPlatform.isDarwin;
    description = "Whether the host provides a graphical desktop.";
  };
}
