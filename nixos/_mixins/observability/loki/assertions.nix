{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ../../../../common/_mixins/observability/loki-model.nix {
    inherit config lib outputs;
  };
in
{
  assertions = [
    {
      assertion = builtins.length (builtins.attrNames model.realmServers) <= 1;
      message = "realm '${config.host.realm}' must not publish multiple Loki servers";
    }
  ];
}
