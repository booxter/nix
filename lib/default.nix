{
  hostInventory,
  inputs,
  outputs,
  username,
  ...
}:
let
  helpers = import ./helpers.nix {
    defaultUsername = username;
    inherit
      hostInventory
      inputs
      outputs
      ;
  };
in
{
  inherit (helpers)
    mkDarwin
    mkNixos
    mkVM
    forAllSystems
    ;
}
