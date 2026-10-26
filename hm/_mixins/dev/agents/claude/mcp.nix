{ lib, mcps }:
let
  renderStdio = server: {
    type = "stdio";
    inherit (server) command args env;
  };
  renderHttp =
    server:
    {
      type = "http";
      url = mcps.resolveValue server.url;
    }
    // lib.optionalAttrs (server.oauth != null && server.oauth.clientId != null) {
      oauth.clientId = mcps.resolveValue server.oauth.clientId;
    };
in
lib.mapAttrs (_: renderStdio) mcps.stdioServers // lib.mapAttrs (_: renderHttp) mcps.httpServers
