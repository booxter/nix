{
  config,
  lib,
  pkgs,
  ...
}:
let
  yamlFormat = pkgs.formats.yaml { };
  tokenFile = "${config.xdg.configHome}/jiratui/api-token";
  # TODO: use SOPS rendering if work secrets move to SOPS.
  jiratui = pkgs.writeShellApplication {
    name = "jiratui";
    text = ''
      if [ -s ${lib.escapeShellArg tokenFile} ]; then
        JIRA_API_TOKEN="$(< ${lib.escapeShellArg tokenFile})"
        export JIRA_API_TOKEN
      fi
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
    };
  };
}
