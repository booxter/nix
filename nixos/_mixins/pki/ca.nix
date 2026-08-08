{
  config,
  hostInventory,
  hostSpec,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.internalPki.provider;
  realmPki = hostInventory.realms.${config.host.realm}.services.internalPki;
  bootstrapPackage = pkgs.callPackage ./packages/step-ca-bootstrap { };
  caName = "Home Internal PKI";
  certLifetimeDays = 180;
  certLifetime = "${toString (certLifetimeDays * 24)}h0m0s";
  caPort = realmPki.server.port;
  caUrl = "https://${cfg.host}:${toString caPort}";
  caProvisioner = "bootstrap@${hostInventory.site.lan.domain}";
  stepStateDir = cfg.stateDirectory;
  stepPasswordFile = "${stepStateDir}/password.txt";
  caDnsNames = lib.unique (
    hostInventory.toNixosHostCertificateDnsNames hostSpec
    ++ [
      config.networking.hostName
      config.services.avahi.hostName
      (hostInventory.toLocalDnsName config.services.avahi.hostName)
    ]
  );
  bootstrapConfig = (pkgs.formats.json { }).generate "step-ca-bootstrap.json" {
    stateDirectory = stepStateDir;
    name = caName;
    url = caUrl;
    dnsNames = caDnsNames;
    address = ":${toString caPort}";
    provisioner = caProvisioner;
    certificateLifetime = certLifetime;
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe bootstrapPackage)
    "--config"
    bootstrapConfig
    "--step"
    (lib.getExe pkgs.step-cli)
  ];
in
{
  config = lib.mkIf cfg.enable {
    host.observability.enable = true;
    host.observability.nodeExporter.mtls.enable = true;

    networking.firewall.allowedTCPPorts = [ caPort ];

    environment.systemPackages = with pkgs; [
      step-ca
      step-cli
    ];

    users.users.step-ca = {
      isSystemUser = true;
      group = "step-ca";
      home = stepStateDir;
      createHome = false;
    };

    users.groups.step-ca = { };

    # TODO: once CA material is managed explicitly instead of bootstrapped on
    # first boot, switch this host to nixpkgs `services.step-ca`.
    systemd.services.step-ca = {
      description = "Smallstep certificate authority";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "notify";
        User = "step-ca";
        Group = "step-ca";
        UMask = "0077";
        StateDirectory = "step-ca";
        WorkingDirectory = stepStateDir;
        Environment = [
          "HOME=${stepStateDir}"
          "STEPPATH=${stepStateDir}"
        ];
        ExecStartPre = bootstrapCommand;
        ExecStart = "${pkgs.step-ca}/bin/step-ca ${stepStateDir}/config/ca.json --password-file ${stepPasswordFile}";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
