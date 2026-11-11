{
  config,
  lib,
  pinepodsModel,
  ...
}:
let
  inherit (pinepodsModel) cfg package port;
  secretName = "pinepods/subscriptions/api_key";
in
{
  config = lib.mkIf (cfg != null) {
    sops.secrets.${secretName} = {
      mode = "0400";
      restartUnits = [ "pinepods-subscriptions.service" ];
    };

    # The API key scopes this policy to its owner's subscriptions. Each run
    # also restores these settings if they were disabled through the UI.
    systemd.services.pinepods-subscriptions = {
      description = "Enable PinePods downloads and AI for every subscription";
      requires = [ "podman-pinepods.service" ];
      wants = [ "sops-install-secrets.service" ];
      after = [
        "podman-pinepods.service"
        "pinepods-bootstrap-admin.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs [
          (lib.getExe' package "pinepods-enforce-subscriptions")
          "--url"
          "http://127.0.0.1:${toString port}"
          "--api-key-file"
          "%d/api-key"
        ];
        LoadCredential = "api-key:${config.sops.secrets.${secretName}.path}";
        DynamicUser = true;
        TimeoutStartSec = "10min";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_INET" ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };

    systemd.timers.pinepods-subscriptions = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnCalendar = "*-*-* *:00/15:00";
      };
    };
  };
}
