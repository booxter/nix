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
  maasJiraEnabled = config.host.codex.mcp.maasJira.enable;
  maasJiraSecret = "codex/mcp/maas_jira/url";
  effectiveCodexSettings = lib.recursiveUpdate codexConfig.settings (
    lib.optionalAttrs (!config.host.isLaptop) {
      desktop.keepRemoteControlAwakeWhilePluggedIn = false;
    }
    // lib.optionalAttrs maasJiraEnabled {
      mcp_servers.maas_jira = {
        url = config.sops.placeholder.${maasJiraSecret};
        auth = "oauth";
        default_tools_approval_mode = "writes";
      };
    }
  );
  generatedCodexConfig = tomlFormat.generate "codex-system-config" effectiveCodexSettings;
  hostSecretFile = ../../../secrets + "/${config.host.secretDomain}/${hostname}.yaml";
in
{
  options.host.codex.mcp.maasJira.enable = lib.mkEnableOption "the NVIDIA MaaS Jira MCP server";

  config = {
    assertions = [
      {
        assertion = !maasJiraEnabled || config.host.secretDomain == "work";
        message = "NVIDIA MaaS Jira MCP must use the isolated work SOPS domain.";
      }
    ];

    environment.etc."codex/config.toml" = lib.mkIf codexConfigEnabled {
      source =
        if maasJiraEnabled then config.sops.templates."codex-config.toml".path else generatedCodexConfig;
    };

    sops = lib.mkIf maasJiraEnabled {
      defaultSopsFile = hostSecretFile;
      secrets.${maasJiraSecret} = { };
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
