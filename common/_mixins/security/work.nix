{ config, lib, ... }:
lib.mkIf (config.host.realm == "work") {
  host.security.sudo.wheelNeedsPassword = lib.mkDefault true;
}
