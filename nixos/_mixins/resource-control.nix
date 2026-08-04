{
  config,
  hostInventory,
  hostSpecName,
  lib,
  ...
}:
let
  resourceControl = import ../../lib/systemd-resource-control.nix { inherit lib; };
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
  inventory = hostSpec.resourceControl or { };
  settingsByService = resourceControl.compile (inventory.systemServices or { });
  unknownServices = lib.filter (
    name:
    let
      service = config.systemd.services.${name} or { };
    in
    !(builtins.hasAttr "ExecStart" (service.serviceConfig or { }))
  ) (lib.attrNames settingsByService);
in
{
  assertions = [
    {
      assertion = unknownServices == [ ];
      message = "Resource policy references unknown system services: ${lib.concatStringsSep ", " unknownServices}";
    }
  ];

  systemd.services = lib.mapAttrs (_: settings: {
    serviceConfig = lib.mapAttrs (_: lib.mkOverride 900) settings;
  }) settingsByService;
}
