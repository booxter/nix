{
  lib,
  inputs,
  username,
  virtPlatform,
  sshPort,
  ...
}:
{
  virtualisation.vmVariant.virtualisation = {
    host.pkgs = (import inputs.nixpkgs { system = virtPlatform; });
    graphics = false;
  };
  services.getty.autologinUser = username;
  security.sudo.wheelNeedsPassword = false;

  virtualisation.vmVariant.virtualisation.forwardPorts = lib.optionals (sshPort != null) [
    {
      from = "host";
      guest.port = 22;
      host.port = sshPort;
    }
  ];
}
