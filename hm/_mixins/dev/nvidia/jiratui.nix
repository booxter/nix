{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  yamlFormat = pkgs.formats.yaml { };
  tokenFile = "${config.xdg.configHome}/jiratui/api-token";
  repositoriesSecret = osConfig.sops.secrets.jiratuiGitRepositories or null;
  # TODO: use SOPS rendering if work secrets move to SOPS.
  jiratui = pkgs.writeShellApplication {
    name = "jiratui";
    runtimeInputs = lib.optionals (repositoriesSecret != null) [ pkgs.jq ];
    text = ''
      if [ -s ${lib.escapeShellArg tokenFile} ]; then
        JIRA_API_TOKEN="$(< ${lib.escapeShellArg tokenFile})"
        export JIRA_API_TOKEN
      fi
      ${lib.optionalString (repositoriesSecret != null) ''
        # JiraTUI requires an ID-keyed JSON object with names and repository paths.
        # Keep the SOPS value as a newline-separated path list instead.
        GIT_REPOSITORIES="$(jq -R -s -c '
          split("\n")
          | map(select(length > 0))
          | to_entries
          | map({
              key: (.key + 1 | tostring),
              value: {
                name: (.value | rtrimstr("/") | split("/") | last),
                path: .value
              }
            })
          | from_entries
        ' < ${lib.escapeShellArg repositoriesSecret.path})"
        export GIT_REPOSITORIES
      ''}
      exec ${lib.getExe pkgs.jiratui} "$@"
    '';
  };
in
{
  config = lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.nvidia.enable) {
    home.packages = [ jiratui ];

    xdg.configFile."jiratui/config.yaml".source = yamlFormat.generate "jiratui-config.yaml" {
      jira_api_base_url = "https://nvidia.atlassian.net";
      jira_api_username = config.host.hm.email;
      pre_defined_jql_expressions = {
        "1" = {
          label = "Assigned to me, not Done";
          expression = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC";
        };
      };
    };
  };
}
