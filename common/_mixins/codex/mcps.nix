{ config, lib }:
let
  mkMaasService =
    {
      codexName,
      displayName,
      settings ? { },
    }:
    {
      description = "the NVIDIA MaaS ${displayName} MCP server";
      urlSecret = "codex/mcp/${codexName}/url";
      requiredSecretDomain = "work";
      settings = {
        auth = "oauth";
        default_tools_approval_mode = "writes";
      }
      // settings;
      inherit codexName;
    };

  services = {
    maasGitLab = mkMaasService {
      codexName = "maas_gitlab";
      displayName = "GitLab";
    };

    maasJira = mkMaasService {
      codexName = "maas_jira";
      displayName = "Jira";
    };

    maasNVBugs = mkMaasService {
      codexName = "maas_nvbugs";
      displayName = "NVBugs";
    };

    maasRedmine = mkMaasService {
      codexName = "maas_redmine";
      displayName = "Redmine";
    };
  };

  enabledServices = lib.filterAttrs (
    optionName: _: config.host.codex.mcp.${optionName}.enable
  ) services;
  enabledServiceList = lib.attrValues enabledServices;
in
{
  options = lib.mapAttrs (_: service: {
    enable = lib.mkEnableOption service.description;
  }) services;

  enabled = enabledServices != { };

  settings.mcp_servers = lib.mapAttrs' (
    _: service:
    lib.nameValuePair service.codexName (
      service.settings
      // {
        url = config.sops.placeholder.${service.urlSecret};
      }
    )
  ) enabledServices;

  secrets = lib.listToAttrs (
    map (service: lib.nameValuePair service.urlSecret { }) enabledServiceList
  );

  assertions = map (service: {
    assertion = config.host.secretDomain == service.requiredSecretDomain;
    message = "${service.description} must use the isolated ${service.requiredSecretDomain} SOPS domain.";
  }) enabledServiceList;
}
