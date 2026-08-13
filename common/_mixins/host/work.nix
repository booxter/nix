{ config, lib, ... }:
lib.mkIf (config.host.realm == "work") {
  host.management.manageNetworkIdentity = lib.mkDefault false;
}
