{ lib, ... }:
{
  options.host.userEnvironment = {
    preset = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "nvidia"
          "personal"
        ]
      );
      default = null;
      description = "Named policy providing user-environment defaults.";
    };

    roles.developer.enable = lib.mkEnableOption "interactive software development environment";
  };
}
