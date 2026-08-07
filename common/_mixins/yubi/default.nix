{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  residentSsh = hostInventory.yubi.devices.personal.applets.fido2.residentSsh;
in
{
  options.programs.yubi = {
    ssh.enable = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem hostname residentSsh.hosts;
      readOnly = true;
      internal = true;
      description = "Whether the YubiKey inventory assigns this host a resident SSH key.";
    };

    age.enable = lib.mkEnableOption "YubiKey-backed age identity tooling";
  };
}
