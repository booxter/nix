{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.yubi;
  residentSsh = hostInventory.yubi.devices.personal.applets.fido2.residentSsh;
  yubikeySshKey = "${config.home.homeDirectory}/.ssh/${cfg.ssh.keyName}";
  yubikeyAgeIdentityFile = "${config.home.homeDirectory}/.config/sops/age/${cfg.age.identityFileName}";
in
{
  options.programs.yubi = {
    ssh = {
      enable = lib.mkEnableOption "YubiKey-backed resident SSH key defaults";

      keyName = lib.mkOption {
        type = lib.types.str;
        default = residentSsh.keyName;
        description = "Resident SSH key stub filename under ~/.ssh.";
      };
    };

    age = {
      enable = lib.mkEnableOption "YubiKey-backed age identity tooling";

      identityFileName = lib.mkOption {
        type = lib.types.str;
        default = "yubi-nix.txt";
        description = "YubiKey age identity filename under ~/.config/sops/age.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.ssh.enable {
      programs.git.settings.user.signingKey = yubikeySshKey;
      programs.ssh.settings."*".IdentityFile = yubikeySshKey;
    })

    (lib.mkIf cfg.age.enable {
      home.packages = [ pkgs.age-plugin-yubikey ];
      home.sessionVariables.SOPS_AGE_KEY_FILE = lib.mkDefault yubikeyAgeIdentityFile;
    })
  ];
}
