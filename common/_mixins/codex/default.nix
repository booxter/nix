{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  hmConfig = config.home-manager.users.${username};
  codexConfig = hmConfig.programs.codex;
  codexConfigDir =
    if hmConfig.home.preferXdgDirectories then
      "${lib.removePrefix hmConfig.home.homeDirectory hmConfig.xdg.configHome}/codex"
    else
      ".codex";
  tomlFormat = pkgs.formats.toml { };
in
{
  environment.etc."codex/config.toml" =
    lib.mkIf (codexConfig.enable && codexConfig.settings != null && codexConfig.settings != { })
      {
        source = tomlFormat.generate "codex-system-config" codexConfig.settings;
      };

  # Keep Codex's user config writable. Declarative settings are loaded from the
  # lower-precedence system layer, while the app and CLI own the user layer.
  home-manager.users.${username}.home.file."${codexConfigDir}/config.toml".enable =
    lib.mkIf codexConfig.enable (lib.mkForce false);
}
