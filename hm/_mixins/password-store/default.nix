{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  requiredRepositories = osConfig.host.userEnvironment.repositories.required;
  enabled = builtins.elem "pass" requiredRepositories;
in
{
  config = lib.mkIf enabled {
    programs = {
      gpg.enable = true;

      password-store = {
        enable = true;
        settings = {
          # Restore pass location to what was before https://github.com/nix-community/home-manager/pull/7833
          PASSWORD_STORE_DIR = "${config.xdg.dataHome}/password-store";
        };
      };
    };

    services.gpg-agent = {
      enable = true;
      enableSshSupport = false; # it's not 1:1 compatible and can mess output of `ssh-add -l`.
      enableZshIntegration = true;
      pinentry.package = pkgs.pinentry-tty;
    };
  };
}
