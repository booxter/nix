{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  residentSshIdentity = hostInventory.yubi.devices.personal.applets.fido2.residentSshIdentity;
  residentSsh = hostInventory.ssh.userIdentities.${residentSshIdentity};
in
{
  options.programs.yubi = {
    ssh.enable = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem hostname residentSsh.availableOn;
      readOnly = true;
      internal = true;
      description = "Whether the YubiKey inventory assigns this host a resident SSH key.";
    };

    age.enable = lib.mkEnableOption "YubiKey-backed age identity tooling";
  };
}
