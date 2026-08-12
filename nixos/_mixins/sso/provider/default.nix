{
  config,
  pkgs,
  ...
}:
let
  ssoPkgs = import ./pkgs pkgs;
in
{
  imports = [ ./kanidm.nix ];

  _module.args = { inherit ssoPkgs; };

  assertions = [
    {
      assertion = config.host.sso.role != "provider" || config.host.isLinux;
      message = "The realm SSO provider role requires NixOS.";
    }
  ];
}
