{
  config,
  lib,
  osConfig,
  ...
}:
let
  requiredRepositories = osConfig.host.userEnvironment.repositories.required;
in
{
  programs.password-store = lib.mkIf (builtins.elem "pass" requiredRepositories) {
    enable = true;
    settings = {
      # Restore pass location to what was before https://github.com/nix-community/home-manager/pull/7833
      PASSWORD_STORE_DIR = "${config.xdg.dataHome}/password-store";
    };
  };
}
