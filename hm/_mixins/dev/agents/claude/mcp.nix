{ lib, mcps }:
let
  renderStdio = server: {
    type = "stdio";
    inherit (server) command args env;
  };
  renderHttp =
    server:
    let
      clientId = mcps.clientIdFor "claude" server;
    in
    {
      type = "http";
      url = mcps.resolveValue server.url;
    }
    // lib.optionalAttrs (clientId != null) {
      oauth.clientId = mcps.resolveValue clientId;
    };
in
lib.mapAttrs (_: renderStdio) mcps.stdioServers // lib.mapAttrs (_: renderHttp) mcps.httpServers
