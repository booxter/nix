{
  config,
  lib,
  pkgs,
  ...
}:
let
  settings = pkgs.writeText "letterboxd-sync.json" (
    builtins.toJSON {
      jellyfin_url = "https://jf.${config.host.network.publicDomain}";
    }
  );
in
{
  sops.secrets = {
    "letterboxd/account" = { };
    "letterboxd/cookies" = { };
    "jellyfin/apiKey" = { };
  };

  systemd.services.letterboxd-sync = {
    description = "Copy Jellyfin watched movies to Letterboxd";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      StateDirectory = "letterboxd-sync";
      StateDirectoryMode = "0700";
      UMask = "0077";
      LoadCredential = [
        "account:${config.sops.secrets."letterboxd/account".path}"
        "cookies:${config.sops.secrets."letterboxd/cookies".path}"
        "jellyfin-key:${config.sops.secrets."jellyfin/apiKey".path}"
      ];
      ExecStart = "${lib.getExe pkgs.letterboxd-sync} --config ${settings}";
      TimeoutStartSec = "1h";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  systemd.timers.letterboxd-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
