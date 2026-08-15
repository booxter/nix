{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.pki.authority = {
    hostName = "pki";
    rootCaCertificate = ../../../nixos/pki/root-ca.crt;
  };
}
