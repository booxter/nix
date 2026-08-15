{ config, lib, ... }:
{
  options.host.desktop = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = if config.nixpkgs.hostPlatform.isDarwin then { } else null;
    description = "Graphical desktop policy.";
  };
}
