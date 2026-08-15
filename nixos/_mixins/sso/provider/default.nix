{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  kanidmModel = import ./kanidm-model.nix {
    inherit config lib outputs;
  };
  ssoPkgs = import ./pkgs {
    inherit pkgs;
    providerInventory = lib.optionalAttrs (config.host.sso.providerHost != null) {
      ${config.host.realm} = config.host.sso.providerHost;
    };
  };
in
{
  imports = [
    ./kanidm.nix
    ./kanidm-mail-sender.nix
    ./kanidm-person-mail.nix
  ];

  _module.args = {
    inherit kanidmModel ssoPkgs;
  };

  assertions = [
    {
      assertion = config.host.sso.provider == null || config.nixpkgs.hostPlatform.isLinux;
      message = "The realm SSO provider requires NixOS.";
    }
  ];
}
