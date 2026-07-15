{
  config,
  lib,
  pkgs,
  username,
  hostname,
  ...
}:
let
  hmConfig = config.home-manager.users.${username};
  codexConfig = hmConfig.programs.codex;
  codexConfigEnabled =
    codexConfig.enable && codexConfig.settings != null && codexConfig.settings != { };
  codexConfigDir =
    if hmConfig.home.preferXdgDirectories then
      "${lib.removePrefix hmConfig.home.homeDirectory hmConfig.xdg.configHome}/codex"
    else
      ".codex";
  tomlFormat = pkgs.formats.toml { };
  mcps = import ./mcps.nix { inherit config lib; };
  effectiveCodexSettings = lib.recursiveUpdate codexConfig.settings (
    lib.optionalAttrs (!config.host.isLaptop) {
      desktop.keepRemoteControlAwakeWhilePluggedIn = false;
    }
    // lib.optionalAttrs mcps.enabled mcps.settings
  );
  generatedCodexConfig = tomlFormat.generate "codex-system-config" effectiveCodexSettings;
  hostSecretFile = ../../../secrets + "/${config.host.secretDomain}/${hostname}.yaml";
in
{
  options.host.codex.mcp = mcps.options;

  config = {
    assertions = mcps.assertions;

    environment.etc."codex/config.toml" = lib.mkIf codexConfigEnabled {
      source =
        if mcps.enabled then config.sops.templates."codex-config.toml".path else generatedCodexConfig;
    };

    sops = lib.mkIf mcps.enabled {
      defaultSopsFile = hostSecretFile;
      secrets = mcps.secrets;
      templates."codex-config.toml" = {
        owner = username;
        group = "staff";
        mode = "0400";
        content = builtins.readFile generatedCodexConfig;
      };
    };

    # Keep Codex's user config writable. Declarative settings are loaded from the
    # lower-precedence system layer, while the app and CLI own the user layer.
    home-manager.users.${username}.home.file."${codexConfigDir}/config.toml" =
      lib.mkIf codexConfigEnabled
        {
          enable = lib.mkForce false;
        };
  };
}
