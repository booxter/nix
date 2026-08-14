{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.pki.authority = {
    hostName = "pki";
    displayName = "Home Internal PKI";
    rootCaCertificate = ../../../nixos/pki/root-ca.crt;
  };
}
