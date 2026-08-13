{ config, lib, ... }:
lib.mkIf (config.host.realm == "work") {
  host.nix.builder.sshIdentityFileName = lib.mkDefault "jgwxhwdl4x-nix-builder";
}
