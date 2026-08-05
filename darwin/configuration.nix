{
  defaultUsername,
  hostInventory,
  inputs,
  outputs,
}:
{
  name,
  stateVersion,
  hmStateVersion,
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
  isVM = false;
in
inputs.nix-darwin.lib.darwinSystem {
  specialArgs = {
    inherit
      inputs
      outputs
      hostInventory
      hostname
      hostPlatform
      username
      stateVersion
      hmStateVersion
      hmFull
      isBuilder
      isDesktop
      isLaptop
      isWork
      secretDomain
      isVM
      ;
    upsShutdownDelaySeconds = 900;
  };
  modules = [ ./default.nix ] ++ extraModules;
}
