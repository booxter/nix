{
  config,
  lib,
  options,
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
    # Proxmox nodes share this mixin but use an older Paperless module.
    assertions = [
      {
        assertion = options.services.paperless ? extraPythonPackages;
        message = "Paperless requires a NixOS module with Python plugin support.";
      }
    ];
    services.paperless = lib.optionalAttrs (options.services.paperless ? extraPythonPackages) {
      extraPythonPackages = ps: [
        paperlessPackages.bootstrap
        (ps.callPackage ./pkgs/paperless-llm-ocr { })
      ];
    };

    systemd.services.paperless-bootstrap = {
      description = "Apply declarative Paperless users, API token and workflows";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-scheduler.service"
        "sops-install-secrets.service"
      ];
      after = [
        "paperless-scheduler.service"
        "sops-install-secrets.service"
      ];
      before = [
        "paperless-task-queue.service"
        "paperless-consumer.service"
      ];
      unitConfig.RequiresMountsFor = [ config.services.paperless.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        Environment = [ "PAPERLESS_BOOTSTRAP_CONFIG=${bootstrapConfig}" ];
        # The upstream NixOS module exposes administration through Django's
        # `shell -c` subcommand; this argument is Python, not a POSIX shell.
        ExecStart = bootstrapCommand;
      };
    };
    systemd.services.paperless-task-queue.requires = [ "paperless-bootstrap.service" ];
    systemd.services.paperless-consumer.requires = [ "paperless-bootstrap.service" ];
  };
}
