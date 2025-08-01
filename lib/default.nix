{
  inputs,
  outputs,
  username,
  ...
}:
let
  helpers = import ./helpers.nix { inherit inputs outputs username; };
in
{
  inherit (helpers)
    mkDarwin
    mkHome
    mkNixos
    mkRaspberryPi
    mkProxmox
    forAllSystems
    ;
}
