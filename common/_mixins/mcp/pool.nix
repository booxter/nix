{
  config,
  hostSpec,
  lib,
}:
let
  available = _: server: server.realms == null || builtins.elem config.host.realm server.realms;
  availableOnHost = _: server: server.hosts == null || builtins.elem hostSpec.name server.hosts;
  rawPool = lib.filterAttrs (
    name: server: available name server && availableOnHost name server
  ) config.host.mcp.servers;
  secretNamesFor =
    server:
    lib.filter (name: name != null) (
      lib.optionals (server.http != null) [
        server.http.urlSecret
        server.http.oauth.clientIdSecret
      ]
    );
  resolveHttp =
    http:
    http
    // {
      url = if http.urlSecret == null then http.url else config.sops.placeholder.${http.urlSecret};
      urlSecret = null;
      oauth = http.oauth // {
        clientId =
          if http.oauth.clientIdSecret == null then
            http.oauth.clientId
          else
            config.sops.placeholder.${http.oauth.clientIdSecret};
        clientIdSecret = null;
      };
    };
  normalizeServer =
    _: server:
    server
    // {
      secretNames = secretNamesFor server;
      http = if server.http == null then null else resolveHttp server.http;
    };
  pool = lib.mapAttrs normalizeServer rawPool;
  instructions = lib.concatMapStringsSep "\n" (server: server.instructions) (
    lib.filter (server: server.instructions != "") (builtins.attrValues pool)
  );
  requiredSecrets = lib.unique (lib.concatMap secretNamesFor (builtins.attrValues rawPool));
in
{
  inherit instructions pool requiredSecrets;
}
