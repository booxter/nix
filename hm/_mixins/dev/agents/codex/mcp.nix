{
  config,
  lib,
  osConfig,
  pkgs,
}:
let
  homeRealm = osConfig.host.realm == "home";
  httpServers = config.host.hm.dev.codex.mcp.httpServers;
  isSecretValue = builtins.isAttrs;
  resolveValue =
    value: if isSecretValue value then osConfig.sops.placeholder.${value.secret} else value;
  secretsFor =
    server:
    lib.optional (isSecretValue server.url) server.url.secret
    ++ lib.optionals (server.oauth != null && server.oauth.clientId != null) (
      lib.optional (isSecretValue server.oauth.clientId) server.oauth.clientId.secret
    );
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
      url = resolveValue server.url;
    }
    // lib.optionalAttrs (server.oauth != null) {
      auth = "oauth";
    }
    // lib.optionalAttrs (server.oauth != null && server.oauth.clientId != null) {
      oauth.client_id = resolveValue server.oauth.clientId;
    };
  instructions = lib.concatMapStringsSep "\n" (server: server.instructions) (
    lib.filter (server: (server.instructions or "") != "") (
      builtins.attrValues stdioServers ++ builtins.attrValues httpServers
    )
  );
  requiredSecrets = lib.unique (lib.concatMap secretsFor (builtins.attrValues httpServers));
in
{
  inherit instructions requiredSecrets;
  oauthServerNames = builtins.attrNames (
    lib.filterAttrs (_: server: server.oauth != null) httpServers
  );
  settings = lib.mapAttrs (_: renderStdio) stdioServers // lib.mapAttrs (_: renderHttp) httpServers;
}
