{
  config,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      hostSpec
      lib
      outputs
      ;
  };
in
{
  assertions = [
    {
      assertion = model.duplicateNames == [ ];
      message = "Nix cache contributions collide in realm '${config.host.realm}': ${lib.concatStringsSep ", " model.duplicateNames}";
    }
  ];
}
