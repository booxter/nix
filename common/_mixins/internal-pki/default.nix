{ config, lib, ... }:
{
  security.pki.certificateFiles = lib.mkIf (!config.host.isWork) [
    ./home-internal-pki-root-ca.crt
  ];
}
