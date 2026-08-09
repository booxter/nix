{ config, lib }:
let
  enabled = config.host.codex.mcp.maas.enable;
  serviceNames = [
    "maas_gitlab"
    "maas_jira"
    "maas_nvbugs"
    "maas_redmine"
  ];
  oauthClientIdServices = [ "maas_nvbugs" ];
  urlSecret = name: "codex/mcp/${name}/url";
  oauthClientIdSecret = name: "codex/mcp/${name}/oauth/client_id";
  secretNames = map urlSecret serviceNames ++ map oauthClientIdSecret oauthClientIdServices;
in
{
  options.maas.enable = lib.mkEnableOption "NVIDIA MaaS MCP servers";

  inherit enabled;

  settings.mcp_servers = lib.genAttrs serviceNames (
    name:
    {
      auth = "oauth";
      default_tools_approval_mode = "writes";
      url = config.sops.placeholder.${urlSecret name};
    }
    // lib.optionalAttrs (builtins.elem name oauthClientIdServices) {
      oauth.client_id = config.sops.placeholder.${oauthClientIdSecret name};
    }
  );

  secrets = lib.genAttrs secretNames (_: { });

  assertions = [
    {
      assertion = !enabled || config.host.realm == "work";
      message = "NVIDIA MaaS MCP servers require the isolated work SOPS domain.";
    }
  ];
}
