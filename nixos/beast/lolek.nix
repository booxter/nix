{
  config,
  hostInventory,
  hostname,
  inputs,
  ...
}:
let
  hostSpec = hostInventory.nixosHostSpecsByName.${hostname};
in
{
  imports = [
    inputs.lolek.nixosModules.default
  ];

  sops.secrets."lolek/botToken" = {
    owner = "lolek";
    group = "lolek";
    mode = "0400";
  };

  services.lolek = {
    enable = true;
    botTokenFile = config.sops.secrets."lolek/botToken".path;
    hardwareAcceleration.backend = "vaapi";
    hardwareAcceleration.device = hostSpec.hardware.igpu.renderDevice;
  };

  systemd.services.lolek = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
