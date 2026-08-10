{ config, lib, ... }:
let
  servers = config.host.mcp.servers;
  transportValid = server: (server.stdio != null) != (server.http != null);
  httpUrlValid =
    server: server.http == null || (server.http.url != null) != (server.http.urlSecret != null);
  oauthClientIdValid =
    server:
    server.http == null
    || (server.http.oauth.clientId == null || server.http.oauth.clientIdSecret == null);
  oauthAuthValid =
    server:
    server.http == null
    || (
      (server.http.oauth.clientId == null && server.http.oauth.clientIdSecret == null)
      || server.http.auth == "oauth"
    );
  invalidNames =
    predicate: builtins.attrNames (lib.filterAttrs (_: server: !predicate server) servers);
in
{
  config.assertions = [
    {
      assertion = lib.all transportValid (builtins.attrValues servers);
      message = "MCP servers must declare exactly one of stdio or HTTP transport: ${lib.concatStringsSep ", " (invalidNames transportValid)}";
    }
    {
      assertion = lib.all httpUrlValid (builtins.attrValues servers);
      message = "HTTP MCP servers must declare exactly one of url or urlSecret: ${lib.concatStringsSep ", " (invalidNames httpUrlValid)}";
    }
    {
      assertion = lib.all oauthClientIdValid (builtins.attrValues servers);
      message = "MCP OAuth client IDs cannot be both public and secret: ${lib.concatStringsSep ", " (invalidNames oauthClientIdValid)}";
    }
    {
      assertion = lib.all oauthAuthValid (builtins.attrValues servers);
      message = "MCP OAuth client IDs require OAuth authentication: ${lib.concatStringsSep ", " (invalidNames oauthAuthValid)}";
    }
  ];
}
