{
  config,
  fleetInventory,
  inputs,
  lib,
  ...
}:
let
  username = config.host.username;
  userEnvironmentTier = fleetInventory.hosts.${config.networking.hostName}.userEnvironmentTier;
in
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager = {
    extraSpecialArgs = { inherit inputs; };
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${username} = {
      imports = [ ../../../hm ] ++ lib.optional (userEnvironmentTier != "base") ../../../hm/_mixins/vim;
      host.hm.env.tier = userEnvironmentTier;
      home.stateVersion = config.system.stateVersion;
    };
  };
}
