{
  config,
  lib,
  outputs,
  ...
}:
let
  agents = config.host.hermesAgents;
  providerFor = agent: outputs.nixosConfigurations.${agent.providerHost}.config or null;
  assertionsFor =
    name: agent:
    let
      provider = providerFor agent;
      models =
        if provider == null || provider.host.ollama == null then { } else provider.host.ollama.models;
      providerContextLength =
        if provider == null || provider.host.ollama == null then
          null
        else
          provider.host.ollama.contextLength;
      bindNames =
        builtins.attrNames agent.filesystem.inputs ++ builtins.attrNames agent.filesystem.outputs;
    in
    [
      {
        assertion = builtins.match "[a-z0-9][a-z0-9-]*" name != null;
        message = "Hermes Agent instance names may only contain lowercase letters, digits, and hyphens.";
      }
      {
        assertion = provider != null;
        message = "host.hermesAgents.${name}.providerHost must name a known NixOS host.";
      }
      {
        assertion = provider == null || provider.host.realm == config.host.realm;
        message = "Hermes Agent '${name}' and its Ollama provider must be in the same realm.";
      }
      {
        assertion = provider != null && provider.host.ollama != null;
        message = "Hermes Agent '${name}' requires an Ollama-enabled provider host.";
      }
      {
        assertion = builtins.hasAttr agent.model models;
        message = "Hermes Agent '${name}' must select a model advertised by its Ollama provider.";
      }
      {
        assertion = agent.contextLength >= 64000;
        message = "Hermes Agent '${name}' requires a context length of at least 64000 tokens.";
      }
      {
        assertion = providerContextLength != null && providerContextLength >= agent.contextLength;
        message = "Hermes Agent '${name}' context length exceeds its Ollama provider default.";
      }
      {
        assertion = lib.all (document: builtins.match "[^/]+" document != null) (
          builtins.attrNames agent.documents
        );
        message = "Hermes Agent '${name}' document names must be plain filenames.";
      }
      {
        assertion = lib.all (bind: builtins.match "[a-z0-9][a-z0-9-]*" bind != null) bindNames;
        message = "Hermes Agent '${name}' filesystem bind names may only contain lowercase letters, digits, and hyphens.";
      }
    ];
  apiPorts = map (agent: agent.apiPort) (builtins.attrValues agents);
  tunnelPorts = map (agent: agent.ollamaTunnelPort) (builtins.attrValues agents);
in
{
  assertions = lib.concatLists (lib.mapAttrsToList assertionsFor agents) ++ [
    {
      assertion = builtins.length apiPorts == builtins.length (lib.unique apiPorts);
      message = "Hermes Agent API ports must be unique per host.";
    }
    {
      assertion = builtins.length tunnelPorts == builtins.length (lib.unique tunnelPorts);
      message = "Hermes Agent Ollama tunnel ports must be unique per host.";
    }
    {
      assertion = lib.intersectLists apiPorts tunnelPorts == [ ];
      message = "Hermes Agent API and Ollama tunnel ports must not overlap.";
    }
  ];
}
