{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.nix.builder.sshIdentityFileName = lib.mkDefault "id_ed25519";
}
