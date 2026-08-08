{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  service = hostInventory.servicesById.home;
  isLocal = hostInventory.serviceRunsOn config.networking.hostName service;
  administratorName = hostInventory.sso.administrator;
  administrator = hostInventory.sso.users.${administratorName};
  port = config.services.home-assistant.config.http.server_port;
  baseUrl = "http://127.0.0.1:${toString port}";
  clientId = "${baseUrl}/";
  passwordSecret = "home-assistant/bootstrap-password";
  tools = pkgs.callPackage ./packages/home-assistant-tools { };
in
{
  config = lib.mkIf isLocal {
    sops.secrets.${passwordSecret} = {
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
          (lib.getExe tools)
          "bootstrap"
          "--base-url"
          baseUrl
          "--client-id"
          clientId
          "--owner-display-name"
          administrator.displayName
          "--owner-language"
          hostInventory.regional.language.code
          "--owner-username"
          administratorName
          "--password-file"
          config.sops.secrets.${passwordSecret}.path
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
