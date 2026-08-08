{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.sso.provider;
  sso = hostInventory.sso;
  personMailUsers = sso.users;
  personMailSecretName = name: "kanidm-person-mail-address-${name}";
  personMailProvisionService = "kanidm-person-mail-provision";
  personMailProvisionFile = "/run/${personMailProvisionService}/persons.json";
  provisionGroups = lib.mapAttrs (_: _: { }) sso.groups;
  provisionPersons = lib.mapAttrs (
    _: person:
    {
      displayName = person.displayName;
      groups = person.groups;
    }
    // lib.optionalAttrs (person ? legalName) { inherit (person) legalName; }
  ) sso.users;
  package = pkgs.callPackage ./packages/kanidm-person-mail-provision {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  provisionArgs = [
    personMailProvisionFile
  ]
  ++ lib.concatMap (name: [
    name
    config.sops.secrets.${personMailSecretName name}.path
  ]) (builtins.attrNames personMailUsers);
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets = lib.mapAttrs' (
      name: person:
      lib.nameValuePair (personMailSecretName name) {
        key = person.mailAddressSopsKey;
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [
          "${personMailProvisionService}.service"
          "kanidm.service"
        ];
      }
    ) personMailUsers;

    services.kanidm.provision = {
      extraJsonFile = personMailProvisionFile;
      groups = provisionGroups;
      persons = provisionPersons;
    };

    systemd.services.kanidm = {
      requires = [ "${personMailProvisionService}.service" ];
      after = lib.mkAfter [ "${personMailProvisionService}.service" ];
    };

    systemd.services.${personMailProvisionService} = {
      description = "Render Kanidm person email provisioning data";
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [ "kanidm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "kanidm";
        Group = "kanidm";
        RuntimeDirectory = personMailProvisionService;
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = "${lib.getExe package} ${lib.escapeShellArgs provisionArgs}";
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
