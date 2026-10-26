{
  config,
  lib,
  ...
}:
let
  hmConfig = config.home-manager.users.${config.host.username};
  enabled = hmConfig.programs.codex.enable || hmConfig.programs.claude-code.enable;
  mcpSecrets = hmConfig.host.hm.dev.agents.mcp.requiredSecrets;
in
{
  imports = [
    ./codex.nix
    ./claude.nix
  ];

  config.sops.secrets = lib.mkIf enabled (lib.genAttrs mcpSecrets (_: { }));
}
