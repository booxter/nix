{
  config,
  lib,
  paperlessModel,
  paperlessPackages,
  pkgs,
  utils,
  ...
}:
let
  inherit (paperlessModel)
    accessGroups
    bootstrapOwner
    cfg
    passwordSecretName
    ssoApplication
    users
    ;
  bootstrapConfig = (pkgs.formats.json { }).generate "paperless-bootstrap.json" {
    groups = accessGroups;
    token = {
      owner = bootstrapOwner;
      file = config.sops.secrets."paperless/api/token".path;
    };
    users = lib.mapAttrsToList (name: user: {
      username = name;
      email = if name == bootstrapOwner then config.host.mailer.address else "";
      passwordFile = config.sops.secrets.${passwordSecretName name}.path;
      isStaff = builtins.elem ssoApplication.roles.admin user.groups;
      isSuperuser = name == bootstrapOwner;
    }) users;
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' config.services.paperless.manage "paperless-manage")
    "shell"
    "-c"
    "from paperless_bootstrap.django import main; main()"
  ];
in
{
  config = lib.mkIf (cfg != null) {
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
      before = lib.optionals (cfg.gpt != null) [
        "paperless-gpt-configure.service"
        "podman-paperless-gpt.service"
      ];
      unitConfig.RequiresMountsFor = [ config.services.paperless.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        Environment = [
          "PAPERLESS_BOOTSTRAP_CONFIG=${bootstrapConfig}"
          "PYTHONPATH=${paperlessPackages.bootstrap}/${paperlessPackages.bootstrap.python.sitePackages}"
        ];
        # The upstream NixOS module exposes administration through Django's
        # `shell -c` subcommand; this argument is Python, not a POSIX shell.
        ExecStart = bootstrapCommand;
      };
    };
  };
}
