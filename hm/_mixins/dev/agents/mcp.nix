{
  config,
  lib,
  osConfig,
}:
let
  inherit (config.host.hm.dev.agents.mcp) stdioServers httpServers;
  isSecretValue = builtins.isAttrs;
  secretsFor =
    server:
    let
      values = [
        server.url
      ]
      ++ builtins.attrValues server.headers
      ++ lib.optionals (server.oauth != null) (builtins.attrValues server.oauth.clientIds);
    in
    map (value: value.secret) (builtins.filter isSecretValue values);
in
{
  inherit stdioServers httpServers;

  clientIdFor =
    client: server: if server.oauth == null then null else server.oauth.clientIds.${client} or null;

  resolveValue =
    value: if isSecretValue value then osConfig.sops.placeholder.${value.secret} else value;

  instructions = lib.concatStringsSep "\n" (
    lib.unique (
      lib.filter (instructions: instructions != "") (
        map (server: server.instructions) (
          builtins.attrValues stdioServers ++ builtins.attrValues httpServers
        )
      )
    )
  );

  requiredSecrets = lib.unique (lib.concatMap secretsFor (builtins.attrValues httpServers));
}
