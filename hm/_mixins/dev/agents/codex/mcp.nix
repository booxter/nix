{
  config,
  lib,
  osConfig,
}:
let
  mcps = import ../mcp.nix { inherit config lib osConfig; };
  inherit (mcps) stdioServers httpServers resolveValue;
  renderStdio =
    server:
    {
      inherit (server) command;
    }
    // lib.optionalAttrs ((server.args or [ ]) != [ ]) { inherit (server) args; }
    // lib.optionalAttrs ((server.env or { }) != { }) { inherit (server) env; };
  renderHttp =
    server:
    let
      clientId = mcps.clientIdFor "codex" server;
    in
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
    // lib.optionalAttrs (clientId != null) {
      oauth.client_id = resolveValue clientId;
    };
in
{
  inherit (mcps) instructions;
  settings = lib.mapAttrs (_: renderStdio) stdioServers // lib.mapAttrs (_: renderHttp) httpServers;
}
