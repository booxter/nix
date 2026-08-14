{
  config,
  lib,
  pkgs,
  ...
}:
{
  fonts.packages = lib.optionals config.host.userEnvironment.roles.workstation.enable (
    with pkgs.nerd-fonts;
    [
      meslo-lg
      jetbrains-mono
      hack
      fira-code
      symbols-only
    ]
  );
}
