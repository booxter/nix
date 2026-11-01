{ lib, pkgs }:
let
  osConfig.sops.placeholder = {
    authorization = "<authorization>";
    clientId = "<client-id>";
  };
  config =
    (lib.evalModules {
      specialArgs = { inherit osConfig pkgs; };
      modules = [
        ../../hm/_mixins/dev/agents/mcp-options.nix
        {
          host.hm.dev.agents.mcp.httpServers = {
            authenticated = {
              url = "https://example.test/mcp";
              headers = {
                Authorization.secret = "authorization";
                X-Client = "coding-agent";
              };
            };
            public.url = "https://public.example.test/mcp";
            oauth = {
              url = "https://oauth.example.test/mcp";
              oauth.clientIds.codex.secret = "clientId";
            };
          };
        }
      ];
    }).config;
  mcps = import ../../hm/_mixins/dev/agents/mcp.nix { inherit config lib osConfig; };
  codex = import ../../hm/_mixins/dev/agents/codex/mcp.nix { inherit config lib osConfig; };
  claude = import ../../hm/_mixins/dev/agents/claude/mcp.nix { inherit lib mcps; };
  expectedHeaders = {
    Authorization = "<authorization>";
    X-Client = "coding-agent";
  };
in
assert lib.assertMsg (
  lib.sort builtins.lessThan mcps.requiredSecrets == [
    "authorization"
    "clientId"
  ]
) "HTTP MCP header secrets must join the runtime SOPS secret set";
assert lib.assertMsg (
  codex.settings.authenticated.http_headers == expectedHeaders
  && claude.authenticated.headers == expectedHeaders
) "Both coding clients must receive the resolved HTTP MCP headers";
assert lib.assertMsg (
  !(codex.settings.public ? http_headers) && !(claude.public ? headers)
) "Public HTTP MCP servers must not gain empty header settings";
assert lib.assertMsg (
  codex.settings.oauth.oauth.client_id == "<client-id>"
) "HTTP header support must preserve OAuth client configuration";
pkgs.runCommand "agent-mcp" { } ''
  touch "$out"
''
