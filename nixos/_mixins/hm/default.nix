{
  config,
  facts,
  hostSpec,
  inputs,
  ...
}:
let
  username = config.host.username;
in
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager = {
    extraSpecialArgs = {
      inherit
        facts
        hostSpec
        inputs
        ;
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${username} = {
      imports = [ ../../../hm ];
      home.stateVersion = config.system.stateVersion;
    };
  };
}
