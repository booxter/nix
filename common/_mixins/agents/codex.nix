{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  cfg = hmConfig.programs.codex;
  codexHome = hmConfig.home.sessionVariables.CODEX_HOME or "${hmConfig.home.homeDirectory}/.codex";
  configFile = lib.removePrefix "${hmConfig.home.homeDirectory}/" "${codexHome}/config.toml";
  hasMcpSecrets = hmConfig.host.hm.dev.agents.mcp.requiredSecrets != [ ];
  generatedConfig = (pkgs.formats.toml { }).generate "codex-system-config" cfg.settings;
in
{
  config = {
    environment.etc."codex/config.toml" = lib.mkIf cfg.enable {
      source = if hasMcpSecrets then config.sops.templates."codex-config.toml".path else generatedConfig;
    };

    sops.templates."codex-config.toml" = lib.mkIf (cfg.enable && hasMcpSecrets) {
      owner = username;
      file = generatedConfig;
    };

    # Keep Codex's user config writable. Declarative settings are loaded from the
    # lower-precedence system layer, while the app and CLI own the user layer.
    home-manager.users.${username}.home.file.${configFile} = lib.mkIf cfg.enable {
      enable = lib.mkForce false;
    };
  };
}
