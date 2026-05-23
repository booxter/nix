{
  config,
  lib,
  pkgs,
  ...
}:
let
  caName = "Home Internal PKI";
  caPort = 8443;
  caProvisioner = "bootstrap@home.arpa";
  stepStateDir = "/var/lib/step-ca";
  stepPasswordFile = "${stepStateDir}/password.txt";
  stepProvisionerPasswordFile = "${stepStateDir}/provisioner-password.txt";
  caDnsNames = [
    config.networking.hostName
    config.host.dnsName
    config.services.avahi.hostName
    "${config.services.avahi.hostName}.local"
  ];
  caDnsArgs = lib.concatMapStringsSep " " (name: "--dns ${lib.escapeShellArg name}") caDnsNames;
  bootstrapScript = pkgs.writeShellScript "step-ca-bootstrap" ''
    set -eu
    umask 077

    if [ -s "${stepStateDir}/config/ca.json" ]; then
      exit 0
    fi

    if [ ! -s "${stepPasswordFile}" ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 48 > "${stepPasswordFile}"
      chmod 600 "${stepPasswordFile}"
    fi

    if [ ! -s "${stepProvisionerPasswordFile}" ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 48 > "${stepProvisionerPasswordFile}"
      chmod 600 "${stepProvisionerPasswordFile}"
    fi

    exec ${pkgs.step-cli}/bin/step ca init \
      --deployment-type standalone \
      --name ${lib.escapeShellArg caName} \
      ${caDnsArgs} \
      --address ${lib.escapeShellArg ":${toString caPort}"} \
      --provisioner ${lib.escapeShellArg caProvisioner} \
      --password-file ${lib.escapeShellArg stepPasswordFile} \
      --provisioner-password-file ${lib.escapeShellArg stepProvisionerPasswordFile} \
      --acme
  '';
in
{
  # Keep the PKI host off the existing plaintext exporter setup until mTLS is in place.
  host.observability.client.enable = false;

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
      ExecStartPre = bootstrapScript;
      ExecStart = "${pkgs.step-ca}/bin/step-ca ${stepStateDir}/config/ca.json --password-file ${stepPasswordFile}";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}
