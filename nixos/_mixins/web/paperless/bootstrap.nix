{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  isOwner = paperlessService.owner == config.networking.hostName;
  ssoAdministrator = hostInventory.sso.administrator;
  paperlessSso = hostInventory.sso.applications.paperless;
  userNames = builtins.attrNames (
    lib.filterAttrs (
      name: person: name != ssoAdministrator && builtins.elem paperlessSso.userGroup person.groups
    ) hostInventory.sso.users
  );
  paperlessUser =
    if builtins.length userNames == 1 then
      builtins.head userNames
    else
      throw "Paperless bootstrap requires exactly one non-administrator user";
  userPasswordSecret = "paperless/users/${paperlessUser}/password";
  paperlessBootstrap = pkgs.callPackage ./packages/paperless-bootstrap { };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' config.services.paperless.manage "paperless-manage")
    "shell"
    "-c"
    "from paperless_bootstrap.django import main; main()"
  ];
in
{
  config = lib.mkIf isOwner {
    sops.secrets = {
      "paperless/admin/password" = {
        owner = "paperless";
        group = "paperless";
        mode = "0400";
        restartUnits = [
          "paperless-bootstrap.service"
          "paperless-scheduler.service"
        ];
      };
      ${userPasswordSecret} = {
        owner = "paperless";
        group = "paperless";
        mode = "0400";
        restartUnits = [ "paperless-bootstrap.service" ];
      };
      "paperless/api/token" = {
        owner = "paperless";
        group = "paperless";
        mode = "0400";
        restartUnits = [
          "paperless-bootstrap.service"
          "prometheus-paperless-exporter.service"
        ];
      };
    };

    systemd.services.paperless-bootstrap = {
      description = "Apply declarative Paperless users and API token";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-scheduler.service"
        "sops-install-secrets.service"
      ];
      after = [
        "paperless-scheduler.service"
        "sops-install-secrets.service"
      ];
      unitConfig.RequiresMountsFor = [ config.services.paperless.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        Environment = [
          "PAPERLESS_ADMIN_USERNAME=${ssoAdministrator}"
          "PAPERLESS_ADMIN_EMAIL=${hostInventory.user.emails.personal}"
          "PAPERLESS_ADMIN_PASSWORD_FILE=${config.sops.secrets."paperless/admin/password".path}"
          "PAPERLESS_USER_USERNAME=${paperlessUser}"
          "PAPERLESS_USER_PASSWORD_FILE=${config.sops.secrets.${userPasswordSecret}.path}"
          "PAPERLESS_GPT_API_TOKEN_FILE=${config.sops.secrets."paperless/api/token".path}"
          "PYTHONPATH=${paperlessBootstrap}/${paperlessBootstrap.python.sitePackages}"
        ];
        # The upstream NixOS module exposes administration through Django's
        # `shell -c` subcommand; this argument is Python, not a POSIX shell.
        ExecStart = bootstrapCommand;
      };
    };
  };
}
