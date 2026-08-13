{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.ups.credentialMode = lib.mkDefault "sops";
}
