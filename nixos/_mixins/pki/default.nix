{
  config,
  ...
}:
{
  imports = [ ./authority.nix ];

  assertions = [
    {
      assertion = config.host.pki.role != "authority" || config.host.isLinux;
      message = "The realm PKI authority role requires NixOS.";
    }
  ];
}
