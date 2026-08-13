{
  config,
  pkgs,
  ...
}:
let
  ssoPkgs = import ./pkgs {
    inherit pkgs;
    providerInventory.${config.host.realm} = config.networking.hostName;
  };
in
{
  imports = [ ./kanidm.nix ];

  _module.args = { inherit ssoPkgs; };

  assertions = [
    {
      assertion = config.host.sso.role != "provider" || config.nixpkgs.hostPlatform.isLinux;
      message = "The realm SSO provider role requires NixOS.";
    }
  ];
}
