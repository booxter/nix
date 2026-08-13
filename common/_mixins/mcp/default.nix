{
  config,
  lib,
  ...
}:
let
  stdioType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Executable used to start the MCP server.";
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
    };
  };
  httpType = lib.types.submodule {
    options = {
      url = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Public MCP server URL.";
      };
      urlSecret = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "SOPS secret containing the MCP server URL.";
      };
      auth = lib.mkOption {
        type = lib.types.enum [
          "none"
          "oauth"
        ];
        default = "none";
        description = "Authentication protocol used by the MCP server.";
      };
      oauth = {
        clientId = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Public OAuth client ID.";
        };
        clientIdSecret = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "SOPS secret containing the OAuth client ID.";
        };
      };
    };
  };
  serverType = lib.types.submodule {
    options = {
      realms = lib.mkOption {
        type = with lib.types; nullOr (nonEmptyListOf nonEmptyStr);
        default = null;
        description = "Realms where the MCP server is available, or all realms when unset.";
      };
      hosts = lib.mkOption {
        type = with lib.types; nullOr (nonEmptyListOf nonEmptyStr);
        default = null;
        description = "Optional fleet hosts where the MCP server is available.";
      };
      instructions = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Default agent instructions for using the MCP server.";
      };
      stdio = lib.mkOption {
        type = with lib.types; nullOr stdioType;
        default = null;
        description = "Standard-I/O MCP transport configuration.";
      };
      http = lib.mkOption {
        type = with lib.types; nullOr httpType;
        default = null;
        description = "HTTP MCP transport configuration.";
      };
      secretNames = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [ ];
        internal = true;
        description = "SOPS secrets required by the normalized MCP server.";
      };
    };
  };
  model = import ./pool.nix {
    inherit
      config
      lib
      ;
  };
in
{
  imports = [
    ./assertions.nix
    ./servers.nix
  ];

  options.host.mcp = {
    servers = lib.mkOption {
      type = lib.types.attrsOf serverType;
      default = { };
      description = "Declarative MCP server registry.";
    };

    pool = lib.mkOption {
      type = lib.types.attrsOf serverType;
      default = model.pool;
      readOnly = true;
      internal = true;
      description = "MCP servers available in this host's realm and deployment scope.";
    };

    instructions = lib.mkOption {
      type = lib.types.lines;
      default = model.instructions;
      readOnly = true;
      internal = true;
      description = "Default agent instructions for the available MCP servers.";
    };
  };

  config.sops.secrets = lib.genAttrs model.requiredSecrets (_: { });
}
