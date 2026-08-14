{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  codexConfig = hmConfig.programs.codex;
  codexHome = hmConfig.home.sessionVariables.CODEX_HOME or "${hmConfig.home.homeDirectory}/.codex";
  codexConfigFile = lib.removePrefix "${hmConfig.home.homeDirectory}/" "${codexHome}/config.toml";
  hasMcpSecrets = lib.any (server: server.secretNames != [ ]) (
    builtins.attrValues config.host.mcp.pool
  );
  generatedCodexConfig = (pkgs.formats.toml { }).generate "codex-system-config" codexConfig.settings;
in
{
  config = {
    environment.etc."codex/config.toml" = lib.mkIf codexConfig.enable {
      source =
        if hasMcpSecrets then config.sops.templates."codex-config.toml".path else generatedCodexConfig;
    };

    sops = lib.mkIf (codexConfig.enable && hasMcpSecrets) {
      templates."codex-config.toml" = {
        owner = username;
        file = generatedCodexConfig;
      };
    };

    # Keep Codex's user config writable. Declarative settings are loaded from the
    # lower-precedence system layer, while the app and CLI own the user layer.
    home-manager.users.${username}.home.file.${codexConfigFile} = lib.mkIf codexConfig.enable {
      enable = lib.mkForce false;
    };
  };
}
