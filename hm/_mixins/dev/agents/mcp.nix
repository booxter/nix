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
    lib.optional (isSecretValue server.url) server.url.secret
    ++ lib.optionals (server.oauth != null) (
      map (value: value.secret) (
        builtins.filter isSecretValue (builtins.attrValues server.oauth.clientIds)
      )
    );
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
