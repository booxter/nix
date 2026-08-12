{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  realm = facts.realms.${config.host.realm};
  username = config.host.username;
  operatorAgeIdentity = config.host.security.secrets.operator.ageIdentity;
  useYubiAgeIdentity = operatorAgeIdentity != null && operatorAgeIdentity.backend == "yubikey";
  u2f = config.host.security.authentication.u2f;
in
{
  options.host.security.authentication.u2f = {
    enable = lib.mkEnableOption "PAM authentication with a registered U2F credential";

    appId = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Application identifier used by the PAM U2F credential.";
    };

    origin = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Origin used by the PAM U2F credential.";
    };
  };

  config = lib.mkMerge [
    {
      security.sudo.wheelNeedsPassword = lib.mkDefault realm.management.sudoWheelNeedsPassword;

      assertions = [
        {
          assertion = !u2f.enable || (u2f.appId != null && u2f.origin != null);
          message = "host.security.authentication.u2f requires appId and origin";
        }
      ];
    }
    (lib.mkIf useYubiAgeIdentity {
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
    })
    (lib.mkIf u2f.enable {
      environment.systemPackages = [ pkgs.pam_u2f ];

      security.pam.u2f = {
        enable = true;
        control = "sufficient";
        settings = {
          appid = u2f.appId;
          origin = u2f.origin;
          cue = true;
        };
      };
    })
  ];
}
