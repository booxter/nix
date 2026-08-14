{
  lib,
  osConfig,
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

  options.host.hm.userEnvironment.homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";

  config = {
    host.hm = {
      pass.enable = lib.mkDefault osConfig.host.userEnvironment.roles.developer.enable;
      userEnvironment.homerow.enable = lib.mkDefault pkgs.stdenv.hostPlatform.isDarwin;
    };
  };
}
