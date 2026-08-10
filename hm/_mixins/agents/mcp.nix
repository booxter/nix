{ lib, osConfig }:
let
  servers = osConfig.host.mcp.pool;
  renderStdio =
    stdio:
    {
      inherit (stdio) args command;
    }
    // lib.optionalAttrs (stdio.env != { }) { inherit (stdio) env; };
  renderHttp =
    http:
    {
      default_tools_approval_mode = "writes";
      inherit (http) url;
    }
    // lib.optionalAttrs (http.auth != "none") { inherit (http) auth; }
    // lib.optionalAttrs (http.oauth.clientId != null) { oauth.client_id = http.oauth.clientId; };
  renderServer =
    _: server: if server.stdio != null then renderStdio server.stdio else renderHttp server.http;
in
lib.mapAttrs renderServer servers
