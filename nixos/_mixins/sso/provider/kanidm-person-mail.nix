{
  config,
  kanidmModel,
  lib,
  ssoPkgs,
  utils,
  ...
}:
let
  inherit (kanidmModel) enabled;
  personMailUsers = lib.filterAttrs (
    _: person: person.mailAddressSopsKey != null
  ) config.host.sso.users;
  secretName = name: "kanidm-person-mail-address-${name}";
  serviceName = "kanidm-person-mail-provision";
  output = "/run/${serviceName}/persons.json";
  command = utils.escapeSystemdExecArgs (
    [
      (lib.getExe' ssoPkgs.kanidm-person-mail-provision "kanidm-person-mail-provision")
      output
    ]
    ++ lib.concatMap (name: [
      name
      config.sops.secrets.${secretName name}.path
    ]) (builtins.attrNames personMailUsers)
  );
in
{
  config = lib.mkIf (enabled && personMailUsers != { }) {
    sops.secrets = lib.mapAttrs' (
      name: person:
      lib.nameValuePair (secretName name) {
        key = person.mailAddressSopsKey;
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [
          "${serviceName}.service"
          "kanidm.service"
        ];
      }
    ) personMailUsers;

    services.kanidm.provision.extraJsonFile = output;

    systemd.services.kanidm = {
      requires = [ "${serviceName}.service" ];
      after = [ "${serviceName}.service" ];
    };

    systemd.services.${serviceName} = {
      description = "Render Kanidm person email provisioning data";
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [ "kanidm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "kanidm";
        Group = "kanidm";
        RuntimeDirectory = serviceName;
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = command;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
  };
}
