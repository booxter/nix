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
  tomlFormat = pkgs.formats.toml { };
  hasMcpSecrets = lib.any (server: server.secretNames != [ ]) (
    builtins.attrValues config.host.mcp.pool
  );
  generatedCodexConfig = tomlFormat.generate "codex-system-config" codexConfig.settings;
in
{
  config = {
    environment.etc."codex/config.toml" = lib.mkIf codexConfig.enable {
      source =
        if hasMcpSecrets then config.sops.templates."codex-config.toml".path else generatedCodexConfig;
    };

    sops = lib.mkIf hasMcpSecrets {
      templates."codex-config.toml" = {
        owner = username;
        group = "staff";
        mode = "0400";
        content = builtins.readFile generatedCodexConfig;
      };
    };

    # Keep Codex's user config writable. Declarative settings are loaded from the
    # lower-precedence system layer, while the app and CLI own the user layer.
    home-manager.users.${username}.home.file.${codexConfigFile}.enable = lib.mkForce false;
  };
}
