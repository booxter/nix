{ lib, ... }:
let
  bindType = lib.types.attrsOf (lib.types.strMatching "^/.+");
in
{
  options.host.hermesAgents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {
          options = {
            providerHost = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "NixOS host providing Ollama inference for this agent.";
            };

            model = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Ollama model used by this agent.";
            };

            contextLength = lib.mkOption {
              type = lib.types.ints.positive;
              default = 65536;
              description = "Context length configured in Hermes and allocated by Ollama.";
            };

            apiPort = lib.mkOption {
              type = lib.types.port;
              description = "Loopback API port used to submit work to this agent.";
            };

            ollamaTunnelPort = lib.mkOption {
              type = lib.types.port;
              description = "Loopback port of this agent's mTLS tunnel to Ollama.";
            };

            stateDir = lib.mkOption {
              type = lib.types.strMatching "^/.+";
              default = "/var/lib/hermes-agent-${name}";
              description = "Persistent state directory for this agent instance.";
            };

            workingDirectory = lib.mkOption {
              type = lib.types.strMatching "^/.+";
              default = "${config.stateDir}/workspace";
              description = "Working directory presented to this agent.";
            };

            soul = lib.mkOption {
              type = lib.types.path;
              description = "Declarative SOUL.md defining this agent's role.";
            };

            documents = lib.mkOption {
              type = lib.types.attrsOf lib.types.path;
              default = { };
              description = "Declarative reference documents installed in the agent workspace.";
            };

            tools = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = "Nix packages placed on this agent's command search path.";
            };

            supplementaryGroups = lib.mkOption {
              type = lib.types.listOf lib.types.nonEmptyStr;
              default = [ ];
              description = "Additional host groups granted to this agent's Unix user.";
            };

            filesystem = {
              hidden = lib.mkOption {
                type = lib.types.listOf (lib.types.strMatching "^/.+");
                default = [ ];
                description = "Host paths hidden from this agent's mount namespace.";
              };

              inputs = lib.mkOption {
                type = bindType;
                default = { };
                description = "Read-only host paths bound under workspace/input by name.";
              };

              outputs = lib.mkOption {
                type = bindType;
                default = { };
                description = "Writable host paths bound under workspace/output by name.";
              };
            };

            settings = lib.mkOption {
              type = lib.types.attrs;
              default = { };
              description = "Additional Hermes configuration merged below enforced instance settings.";
            };
          };
        }
      )
    );
    default = { };
    description = "Isolated Hermes Agent service instances.";
  };
}
