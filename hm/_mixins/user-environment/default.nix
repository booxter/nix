{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./nvidia.nix
    ./personal.nix
    ./repositories.nix
    ./smtp.nix
  ];

  options.host.hm.userEnvironment = {
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

    homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";
  };

  config = {
    host.hm = {
      pass.enable = lib.mkDefault (config.host.hm.userEnvironment.preset != null);
      userEnvironment.homerow.enable = lib.mkDefault pkgs.stdenv.hostPlatform.isDarwin;
    };
  };
}
