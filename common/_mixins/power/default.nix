{
  config,
  lib,
  outputs,
  ...
}:
let
  hostName = config.networking.hostName;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  imports = [ ./assertions.nix ];

  options.host.power.shutdown = {
    before = lib.mkOption {
      type = with lib.types; attrsOf (listOf nonEmptyStr);
      default = { };
      internal = true;
      description = "Hosts that must remain available until this host shuts down.";
    };

    delaySeconds = lib.mkOption {
      type = with lib.types; nullOr ints.positive;
      default = model.delays.${hostName} or null;
      readOnly = true;
      internal = true;
      description = "Derived delay after an on-battery event before shutdown.";
    };
  };
}
