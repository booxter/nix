{ config, lib, ... }:
{
  options.host.internalPki.rootCaCertificate = lib.mkOption {
    type = lib.types.path;
    default = ./home-internal-pki-root-ca.crt;
    readOnly = true;
    internal = true;
    description = "Root CA certificate for the home internal PKI.";
  };

  config.security.pki.certificateFiles = lib.mkIf (!config.host.isWork) [
    config.host.internalPki.rootCaCertificate
  ];
}
