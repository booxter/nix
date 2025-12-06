{
  inputs,
  outputs,
  username,
  ci ? false,
  ...
}:
let
  helpers = import ./helpers.nix {
    inherit
      inputs
      outputs
      username
      ci
      ;
  };
in
{
  inherit (helpers)
    mkDarwin
    mkHome
    mkNixos
    mkRaspberryPi
    mkProxmox
    mkVM
    forAllSystems
    ;
}
