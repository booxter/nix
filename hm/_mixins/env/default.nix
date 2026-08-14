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

  options.host.hm.env = {
    preset = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "nvidia"
          "personal"
        ]
      );
      default = null;
      description = "Named policy providing environment defaults.";
    };

    homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";
  };

  config = {
    host.hm = {
      pass.enable = lib.mkDefault (config.host.hm.env.preset != null);
      env.homerow.enable = lib.mkDefault pkgs.stdenv.hostPlatform.isDarwin;
    };
  };
}
