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

      localOnly = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use the YubiKey SSH identity only outside SSH login sessions.";
      };

      remoteFallbackKeyName = lib.mkOption {
        type = lib.types.str;
        default = "id_ed25519";
        description = "Password-protected SSH key filename under ~/.ssh for SSH login sessions.";
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

      sshSudoPassword = {
        enable = lib.mkEnableOption "password-only sudo authentication for interactive SSH sessions";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.ssh.enable {
      home-manager.users.${username}.programs.yubi.ssh = {
        enable = true;
        inherit (cfg.ssh) keyName localOnly remoteFallbackKeyName;
      };
    })

    (lib.mkIf cfg.age.enable {
      home-manager.users.${username}.programs.yubi.age = {
        enable = true;
        inherit (cfg.age) identityFileName;
      };
    })

    (lib.optionalAttrs isLinux (
      lib.mkIf cfg.age.enable {
        services.pcscd.enable = true;
        security.polkit = {
          enable = true;
          extraConfig = ''
            polkit.addRule(function(action, subject) {
              if ((action.id == "org.debian.pcsc-lite.access_pcsc" ||
                   action.id == "org.debian.pcsc-lite.access_card") &&
                  subject.user == "${username}") {
                return polkit.Result.YES;
              }
            });
          '';
        };
      }
    ))

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

        environment.etc."pam.d/sudo_ssh_password" = lib.mkIf cfg.smartCard.sshSudoPassword.enable {
          text = ''
            # sudo_ssh_password: auth account password session
            auth       required       pam_opendirectory.so
            account    required       pam_permit.so
            password   required       pam_deny.so
            session    required       pam_permit.so
          '';
        };

        security.sudo.extraConfig = lib.mkIf cfg.smartCard.sshSudoPassword.enable (
          lib.mkAfter ''
            Defaults    pam_askpass_service=sudo_ssh_password
          ''
        );

        home-manager.users.${username}.programs.yubi.smartCard.sshSudoPassword.enable =
          cfg.smartCard.sshSudoPassword.enable;
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
