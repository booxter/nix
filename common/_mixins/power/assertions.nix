{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  formatEdge = edge: "${edge.host} -> ${edge.target}";
in
{
  config.assertions = [
    {
      assertion = model.unknownTargets == [ ];
      message = "shutdown dependencies reference unknown hosts: ${
        lib.concatMapStringsSep ", " formatEdge model.unknownTargets
      }";
    }
    {
      assertion = model.cycleHosts == [ ];
      message = "shutdown dependency graph contains cycles involving: ${lib.concatStringsSep ", " model.cycleHosts}";
    }
    {
      assertion = model.invalidUpsServers == [ ];
      message = "UPS clients do not resolve to enabled UPS servers: ${lib.concatStringsSep ", " model.invalidUpsServers}";
    }
    {
      assertion = model.invalidPowerEdges == [ ];
      message = "shutdown dependencies cross UPS domains: ${
        lib.concatMapStringsSep ", " formatEdge model.invalidPowerEdges
      }";
    }
    {
      assertion = model.invalidDelays == [ ];
      message = "UPS shutdown policy produces missing or non-positive delays for: ${lib.concatStringsSep ", " model.invalidDelays}";
    }
  ];
}
