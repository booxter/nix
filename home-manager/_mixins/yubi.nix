{ config, lib, ... }:
let
  cfg = config.programs.yubi.ssh;
  yubikeySshKey = "${config.home.homeDirectory}/.ssh/${cfg.keyName}";
in
{
  options.programs.yubi.ssh = {
    enable = lib.mkEnableOption "YubiKey-backed resident SSH key defaults";

    keyName = lib.mkOption {
      type = lib.types.str;
      default = "id_ed25519_sk_rk";
      description = "Resident SSH key stub filename under ~/.ssh.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.git.settings.user.signingKey = yubikeySshKey;
    programs.ssh.settings."*".IdentityFile = yubikeySshKey;
  };
}
