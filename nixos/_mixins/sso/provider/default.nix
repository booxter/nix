{
  config,
  lib,
  pkgs,
  ...
}:
let
  ssoPkgs = import ./pkgs {
    inherit pkgs;
    providerInventory = lib.optionalAttrs (config.host.sso.providerHost != null) {
      ${config.host.realm} = config.host.sso.providerHost;
    };
  };
in
{
  imports = [ ./kanidm.nix ];

  _module.args = { inherit ssoPkgs; };

  assertions = [
    {
      assertion = config.host.sso.provider == null || config.nixpkgs.hostPlatform.isLinux;
      message = "The realm SSO provider requires NixOS.";
    }
  ];
}
