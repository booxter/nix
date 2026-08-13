{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  security.sudo.wheelNeedsPassword = lib.mkDefault false;
}
