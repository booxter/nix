{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  maasServer = name: {
    realms = [ "work" ];
    hosts = [ "JGWXHWDL4X" ];
    http = {
      urlSecret = "codex/mcp/${name}/url";
      auth = "oauth";
    }
    // lib.optionalAttrs (name == "maas_nvbugs") {
      oauth.clientIdSecret = "codex/mcp/${name}/oauth/client_id";
    };
  };
in
{
  config.host.mcp.servers = {
    nixos = {
      stdio.command = lib.getExe pkgs.mcp-nixos;
    };

    firefox-devtools = {
      realms = [ "home" ];
      instructions = ''
        Only use the Firefox DevTools MCP when the user explicitly requests browser
        interaction or browser-based debugging.
      '';
      stdio = {
        command = lib.getExe pkgs.firefox-devtools-mcp;
        args = [
          "--profile-path"
          "${hmConfig.xdg.dataHome}/firefox-devtools-mcp"
          "--accept-insecure-certs"
          "--viewport"
          "1440x1000"
        ];
      };
    };

    maas_gitlab = maasServer "maas_gitlab";
    maas_jira = maasServer "maas_jira";
    maas_nvbugs = maasServer "maas_nvbugs";
    maas_redmine = maasServer "maas_redmine";
  };
}
