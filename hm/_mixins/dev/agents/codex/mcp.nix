{
  config,
  lib,
  osConfig,
  pkgs,
}:
let
  homeRealm = osConfig.host.realm == "home";
  workHost = osConfig.host.realm == "work" && osConfig.networking.hostName == "JGWXHWDL4X";
  maasNames = [
    "maas_gitlab"
    "maas_jira"
    "maas_nvbugs"
    "maas_redmine"
  ];
  urlSecretFor = name: "codex/mcp/${name}/url";
  clientIdSecretFor = name: "codex/mcp/${name}/oauth/client_id";
  stdioServers = {
    nixos.command = lib.getExe pkgs.mcp-nixos;
  }
  // lib.optionalAttrs homeRealm {
    firefox-devtools = {
      instructions = ''
        Only use the Firefox DevTools MCP when the user explicitly requests browser
        interaction or browser-based debugging.
      '';
      command = lib.getExe pkgs.firefox-devtools-mcp;
      args = [
        "--profile-path"
        "${config.xdg.dataHome}/firefox-devtools-mcp"
        "--accept-insecure-certs"
        "--viewport"
        "1440x1000"
      ];
    };
  };
  httpServers = lib.optionalAttrs workHost (
    lib.genAttrs maasNames (name: {
      url = osConfig.sops.placeholder.${urlSecretFor name};
      oauth =
        { }
        // lib.optionalAttrs (name == "maas_nvbugs") {
          clientId = osConfig.sops.placeholder.${clientIdSecretFor name};
        };
    })
  );
  renderStdio =
    server:
    {
      inherit (server) command;
    }
    // lib.optionalAttrs (server ? args) { inherit (server) args; }
    // lib.optionalAttrs (server ? env) { inherit (server) env; };
  renderHttp =
    server:
    {
      default_tools_approval_mode = "writes";
      inherit (server) url;
      auth = "oauth";
    }
    // lib.optionalAttrs (server.oauth ? clientId) { oauth.client_id = server.oauth.clientId; };
  instructions = lib.concatMapStringsSep "\n" (server: server.instructions) (
    lib.filter (server: (server.instructions or "") != "") (
      builtins.attrValues stdioServers ++ builtins.attrValues httpServers
    )
  );
  requiredSecrets = lib.optionals workHost (
    map urlSecretFor maasNames ++ [ (clientIdSecretFor "maas_nvbugs") ]
  );
in
{
  inherit instructions requiredSecrets;
  oauthServerNames = builtins.attrNames httpServers;
  settings = lib.mapAttrs (_: renderStdio) stdioServers // lib.mapAttrs (_: renderHttp) httpServers;
}
