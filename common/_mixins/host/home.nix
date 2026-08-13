{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.management.manageNetworkIdentity = lib.mkDefault true;
}
