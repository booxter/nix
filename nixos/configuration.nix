{
  defaultUsername,
  hostInventory,
  inputs,
  outputs,
}:
{
  name,
  stateVersion,
  username ? defaultUsername,
  platform,
  hmFull ? true,
  isBuilder ? false,
  isDesktop ? false,
  isLaptop ? false,
  isWork ? false,
  secretDomain ? (if isWork then "work" else "main"),
  extraModules ? [ ],
  ...
}:
let
  hostname = name;
  hostPlatform = inputs.nixpkgs.lib.systems.elaborate platform;
in
inputs.nixpkgs.lib.nixosSystem {
  specialArgs = {
    inherit
      inputs
      outputs
      hostInventory
      hostname
      hostPlatform
      username
      stateVersion
      hmFull
      isBuilder
      isDesktop
      isLaptop
      isWork
      secretDomain
      ;
  };
  modules = [ ./default.nix ] ++ extraModules;
}
