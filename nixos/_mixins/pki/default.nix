{
  config,
  ...
}:
{
  imports = [ ./authority.nix ];

  assertions = [
    {
      assertion = config.host.pki.role != "authority" || config.nixpkgs.hostPlatform.isLinux;
      message = "The realm PKI authority role requires NixOS.";
    }
  ];
}
