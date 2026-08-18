{
  config,
  lib,
  osConfig,
  pkgs,
}:
let
  stdioServers = {
    nixos.command = lib.getExe pkgs.mcp-nixos;
  }
  // config.host.hm.dev.codex.mcp.stdioServers;
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
  renderStdio =
    server:
    {
      inherit (server) command;
    }
    // lib.optionalAttrs ((server.args or [ ]) != [ ]) { inherit (server) args; }
    // lib.optionalAttrs ((server.env or { }) != { }) { inherit (server) env; };
  renderHttp =
    server:
    {
      default_tools_approval_mode = "writes";
      url = resolveValue server.url;
    }
    // lib.optionalAttrs (server.startupTimeoutSec != null) {
      startup_timeout_sec = server.startupTimeoutSec;
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
  settings = lib.mapAttrs (_: renderStdio) stdioServers // lib.mapAttrs (_: renderHttp) httpServers;
}
