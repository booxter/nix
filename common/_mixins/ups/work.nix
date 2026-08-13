{ config, lib, ... }:
lib.mkIf (config.host.realm == "work") {
  host.ups.credentialMode = lib.mkDefault "literal";
}
