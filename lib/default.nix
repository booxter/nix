{
  inputs,
  outputs,
  stateVersion,
  username,
  ...
}:
let
  helpers = import ./helpers.nix { inherit inputs outputs stateVersion username; };
in
{
  inherit (helpers)
    mkDarwin
    mkHome
    mkNixos
    forAllSystems
    ;
}
