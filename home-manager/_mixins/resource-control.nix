{
  config,
  hostInventory,
  hostSpecName,
  isDarwin,
  lib,
  ...
}:
let
  resourceControl = import ../../lib/systemd-resource-control.nix { inherit lib; };
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
  inventory = hostSpec.resourceControl or { };
  settingsByService = resourceControl.compile (inventory.userServices or { });
  unknownServices = lib.filter (
    name:
    builtins.removeAttrs config.systemd.user.services.${name}.Service (
      lib.attrNames settingsByService.${name}
    ) == { }
  ) (lib.attrNames settingsByService);
in
{
  assertions = lib.optionals (!isDarwin) [
    {
      assertion = unknownServices == [ ];
      message = "Resource policy references unknown user services: ${lib.concatStringsSep ", " unknownServices}";
    }
  ];

  systemd.user.services = lib.mkIf (!isDarwin) (
    lib.mapAttrs (_: settings: {
      Service = lib.mapAttrs (_: lib.mkOverride 900) settings;
    }) settingsByService
  );
}
