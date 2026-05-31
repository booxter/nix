{
  hostInventory,
  inputs,
  outputs,
  username,
  ...
}:
let
  helpers = import ./helpers.nix {
    inherit
      hostInventory
      inputs
      outputs
      username
      ;
  };
in
{
  inherit (helpers)
    mkDarwin
    mkNixos
    mkProxmox
    mkBM
    mkVM
    mkVmHostPkgs
    forAllSystems
    ;
}
