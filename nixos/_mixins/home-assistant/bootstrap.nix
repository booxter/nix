{
  config,
  lib,
  ...
}:
let
  cfg = config.host.home-assistant;
  homeAssistantSso = config.host.sso.applications.home-assistant;
  bootstrapOwnerName = homeAssistantSso.bootstrapOwner;
  bootstrapPasswordSecret = "home-assistant/bootstrap-password";
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets.${bootstrapPasswordSecret} = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "home-assistant-bootstrap.service" ];
    };

    systemd.services.home-assistant-bootstrap = {
      description = "Bootstrap Home Assistant owner and onboarding state";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "home-assistant.service"
        "sops-install-secrets.service"
      ];
      after = [
        "home-assistant.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [
          (lib.getExe cfg.internal.tools)
          "bootstrap"
          "--base-url"
          cfg.localUrl
          "--client-id"
          "${cfg.localUrl}/"
          "--owner-display-name"
          bootstrapOwnerName
          "--owner-language"
          homeAssistantSso.bootstrapLanguage
          "--owner-username"
          bootstrapOwnerName
          "--password-file"
          config.sops.secrets.${bootstrapPasswordSecret}.path
        ];
        User = "root";
        Group = "root";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
