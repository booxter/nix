{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.security.sudo.wheelNeedsPassword = lib.mkDefault false;
}
