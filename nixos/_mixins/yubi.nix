{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  operatorAgeIdentity = config.host.security.secrets.operator.ageIdentity;
  useYubiAgeIdentity = operatorAgeIdentity != null && operatorAgeIdentity.backend == "yubikey";
  pamU2f = facts.yubi.devices.personal.applets.fido2.pamU2f.${hostname} or null;
in
{
  config = lib.mkMerge [
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

    (lib.mkIf (pamU2f != null) {
      environment.systemPackages = [ pkgs.pam_u2f ];

      security.pam.u2f = {
        enable = true;
        control = "sufficient";
        settings = {
          appid = pamU2f.appId;
          origin = pamU2f.origin;
          cue = true;
        };
      };
    })
  ];
}
