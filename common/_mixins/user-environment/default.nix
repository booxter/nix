{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
in
{
  imports = [
    ./nvidia.nix
    ./personal.nix
    ./repositories.nix
    ./smtp.nix
  ];

  options.host.userEnvironment = {
    preset = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "nvidia"
          "personal"
        ]
      );
      default = null;
      description = "Named fleet policy providing overridable user-environment defaults.";
    };

    roles.developer.enable = lib.mkEnableOption "interactive software development environment";

    homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";
  };

  config = {
    host.userEnvironment.homerow.enable = lib.mkDefault config.nixpkgs.hostPlatform.isDarwin;

    home-manager.users.${config.host.username}.host.hm.pass.enable =
      lib.mkDefault cfg.roles.developer.enable;
  };
}
