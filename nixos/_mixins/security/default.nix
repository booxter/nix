{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  operatorAgeIdentity = config.host.security.secrets.operator.ageIdentity;
  useYubiAgeIdentity = operatorAgeIdentity != null && operatorAgeIdentity.backend == "yubikey";
in
{
  imports = [
    ./home.nix
    ./work.nix
  ];

  config = lib.mkIf useYubiAgeIdentity {
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
  };
}
