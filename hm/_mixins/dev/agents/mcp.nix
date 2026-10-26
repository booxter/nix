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
    ++ lib.optionals (server.oauth != null && server.oauth.clientId != null) (
      lib.optional (isSecretValue server.oauth.clientId) server.oauth.clientId.secret
    );
in
{
  inherit stdioServers httpServers;

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
