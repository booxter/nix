{
  config,
  hostInventory,
  hostname,
  isDarwin,
  isLinux,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.programs.yubi;
  personalYubi = hostInventory.yubi.devices.personal;
  residentSsh = personalYubi.applets.fido2.residentSsh;
  pamU2fDefaults =
    personalYubi.applets.fido2.pamU2f.${hostname} or {
      appId = "pam://${hostname}";
      origin = "pam://${hostname}";
    };
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

    pamU2f = {
      enable = lib.mkEnableOption "YubiKey PAM U2F authentication";

      appId = lib.mkOption {
        type = lib.types.str;
        default = pamU2fDefaults.appId;
        description = "PAM U2F application ID.";
      };

      origin = lib.mkOption {
        type = lib.types.str;
        default = pamU2fDefaults.origin;
        description = "PAM U2F origin.";
      };

      control = lib.mkOption {
        type = lib.types.str;
        default = "sufficient";
        description = "PAM control value for pam_u2f.";
      };

      cue = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether pam_u2f should prompt before waiting for touch.";
      };
    };

    smartCard = {
      enable = lib.mkEnableOption "macOS SmartCardServices defaults for YubiKey PIV login";

      userPairing = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether macOS should show the smart-card pairing UI for unpaired cards.";
      };

      allowUnmappedUsers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether users without smart-card mappings may continue to log in with passwords.";
      };

      checkCertificateTrust = lib.mkOption {
        type = lib.types.ints.between 0 3;
        default = 0;
        description = "Smart-card certificate trust checking level.";
      };

      enforceSmartCard = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether macOS should require smart-card authentication.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.ssh.enable {
      home-manager.users.${username}.programs.yubi.ssh = {
        enable = true;
        inherit (cfg.ssh) keyName;
      };
    })

    (lib.optionalAttrs isLinux (
      lib.mkIf cfg.pamU2f.enable {
        environment.systemPackages = [ pkgs.pam_u2f ];

        security.pam.u2f = {
          enable = true;
          inherit (cfg.pamU2f) control;
          settings = {
            appid = cfg.pamU2f.appId;
            inherit (cfg.pamU2f) cue origin;
          };
        };
      }
    ))

    (lib.optionalAttrs isDarwin (
      lib.mkIf cfg.smartCard.enable {
        system.defaults.CustomSystemPreferences."/Library/Preferences/com.apple.security.smartcard" = {
          UserPairing = cfg.smartCard.userPairing;
          allowUnmappedUsers = if cfg.smartCard.allowUnmappedUsers then 1 else 0;
          checkCertificateTrust = cfg.smartCard.checkCertificateTrust;
          enforceSmartCard = cfg.smartCard.enforceSmartCard;
        };
      }
    ))

    {
      assertions = [
        {
          assertion = (!cfg.pamU2f.enable) || isLinux;
          message = "programs.yubi.pamU2f.enable is only supported on Linux hosts.";
        }
        {
          assertion = (!cfg.smartCard.enable) || isDarwin;
          message = "programs.yubi.smartCard.enable is only supported on Darwin hosts.";
        }
      ];
    }
  ];
}
