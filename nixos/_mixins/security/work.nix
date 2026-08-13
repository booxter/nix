{ config, lib, ... }:
lib.mkIf (config.host.realm == "work") {
  security.sudo.wheelNeedsPassword = lib.mkDefault true;
}
