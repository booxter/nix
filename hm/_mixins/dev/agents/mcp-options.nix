{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  secretValueType = lib.types.either lib.types.nonEmptyStr (
    lib.types.submodule {
      options.secret = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SOPS secret containing the MCP configuration value.";
      };
    }
  );
  instructions = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = "Agent instructions for using the MCP server.";
  };
  stdioServerType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Executable used to start the stdio MCP server.";
      };
      args = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Arguments passed to the MCP server executable.";
      };
      env = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        description = "Environment variables passed to the MCP server.";
      };
      inherit instructions;
    };
  };
  httpServerType = lib.types.submodule {
    options = {
      url = lib.mkOption {
        type = secretValueType;
        description = "Public URL or SOPS-backed URL for the HTTP MCP server.";
      };
      oauth = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options.clientId = lib.mkOption {
              type = lib.types.nullOr secretValueType;
              default = null;
              description = "Public or SOPS-backed OAuth client ID.";
            };
          }
        );
        default = null;
        description = "OAuth configuration, or null for an unauthenticated HTTP server.";
      };
      startupTimeoutSec = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Seconds to wait for the MCP server to initialize, where supported by the client.";
      };
      inherit instructions;
    };
  };
  mcps = import ./mcp.nix {
    inherit config lib osConfig;
  };
in
{
  options.host.hm.dev.agents.mcp = {
    stdioServers = lib.mkOption {
      type = lib.types.attrsOf stdioServerType;
      default = { };
      description = "Stdio MCP servers shared by coding agents.";
    };
    httpServers = lib.mkOption {
      type = lib.types.attrsOf httpServerType;
      default = { };
      description = "HTTP MCP servers shared by coding agents.";
    };
    requiredSecrets = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = mcps.requiredSecrets;
      readOnly = true;
      internal = true;
      description = "SOPS secrets required by shared MCP servers.";
    };
  };

  config.host.hm.dev.agents.mcp.stdioServers.nixos.command = lib.mkDefault (
    lib.getExe pkgs.mcp-nixos
  );
}
