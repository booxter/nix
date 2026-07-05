{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.programs.yubi.ssh;
  residentSsh = hostInventory.yubi.devices.personal.applets.fido2.residentSsh;
  yubikeySshKey = "${config.home.homeDirectory}/.ssh/${cfg.keyName}";
in
{
  options.programs.yubi.ssh = {
    enable = lib.mkEnableOption "YubiKey-backed resident SSH key defaults";

    keyName = lib.mkOption {
      type = lib.types.str;
      default = residentSsh.keyName;
      description = "Resident SSH key stub filename under ~/.ssh.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.git.settings.user.signingKey = yubikeySshKey;
    programs.ssh.settings."*".IdentityFile = yubikeySshKey;
  };
}
